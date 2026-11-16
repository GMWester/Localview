import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

/// Length-prefixed (u32 big endian) frames over a TCP socket.
class FramedSocket {
  FramedSocket(this.socket) {
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    _sub = socket.listen(_onData, onError: (Object e) => _fail(e), onDone: () => _fail(null), cancelOnError: true);
  }

  static const int maxFrame = 64 * 1024 * 1024;

  final Socket socket;
  late final StreamSubscription<Uint8List> _sub;
  final Queue<Uint8List> _frames = Queue();
  Completer<void>? _waiter;
  final List<Uint8List> _chunks = [];
  int _buffered = 0;
  bool _closed = false;
  Object? _error;

  bool get isClosed => _closed;
  InternetAddress get remoteAddress => socket.remoteAddress;

  void _onData(Uint8List data) {
    _chunks.add(data);
    _buffered += data.length;
    while (true) {
      if (_buffered < 4) break;
      final head = _peek(4);
      final len = ByteData.sublistView(head).getUint32(0);
      if (len > maxFrame) {
        _fail(const FormatException('frame too large'));
        socket.destroy();
        return;
      }
      if (_buffered < 4 + len) break;
      _take(4);
      _frames.add(_take(len));
    }
    _wake();
  }

  Uint8List _peek(int n) {
    final out = Uint8List(n);
    var o = 0;
    for (final c in _chunks) {
      final m = (n - o) < c.length ? (n - o) : c.length;
      out.setRange(o, o + m, c);
      o += m;
      if (o == n) break;
    }
    return out;
  }

  Uint8List _take(int n) {
    if (n == 0) return Uint8List(0);
    if (_chunks.first.length == n) {
      _buffered -= n;
      return _chunks.removeAt(0);
    }
    if (_chunks.first.length > n) {
      final c = _chunks.first;
      final out = Uint8List.fromList(Uint8List.sublistView(c, 0, n));
      _chunks[0] = Uint8List.sublistView(c, n);
      _buffered -= n;
      return out;
    }
    final out = Uint8List(n);
    var o = 0;
    while (o < n) {
      final c = _chunks.first;
      final m = (n - o) < c.length ? (n - o) : c.length;
      out.setRange(o, o + m, c);
      o += m;
      if (m == c.length) {
        _chunks.removeAt(0);
      } else {
        _chunks[0] = Uint8List.sublistView(c, m);
      }
    }
    _buffered -= n;
    return out;
  }

  void _wake() {
    final w = _waiter;
    _waiter = null;
    w?.complete();
  }

  void _fail(Object? e) {
    _closed = true;
    _error ??= e;
    _wake();
  }

  /// Next frame, or throws [SocketException] when the connection closed.
  Future<Uint8List> next({Duration? timeout}) async {
    final deadline = timeout == null ? null : DateTime.now().add(timeout);
    while (_frames.isEmpty) {
      if (_closed) throw SocketException('connection closed${_error != null ? ': $_error' : ''}');
      final w = _waiter ??= Completer<void>();
      if (deadline != null) {
        final left = deadline.difference(DateTime.now());
        if (left.isNegative) throw TimeoutException('timed out waiting for peer');
        await w.future.timeout(left, onTimeout: () {});
      } else {
        await w.future;
      }
    }
    return _frames.removeFirst();
  }

  void send(List<int> data) {
    if (_closed) return;
    final h = ByteData(4)..setUint32(0, data.length);
    socket.add(h.buffer.asUint8List());
    socket.add(data);
  }

  Future<void> close() async {
    _closed = true;
    try {
      await socket.flush().timeout(const Duration(seconds: 1));
    } catch (_) {}
    socket.destroy();
    await _sub.cancel();
    _wake();
  }
}
