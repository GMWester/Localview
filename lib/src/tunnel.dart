// TCP tunnels through an end-to-end encrypted Localview session.
//
// Used for "ADB over Localview": the viewer listens on 127.0.0.1:<local port>; each
// connection there is carried through the session to 127.0.0.1:<port> on the host (an
// Android device's adbd), so `adb pair` / `adb connect 127.0.0.1:<local port>` work as if
// the phone were attached with a cable. The host only accepts tunnels when its owner
// turned "ADB over Localview" on, and only to its own loopback address.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

abstract final class TunnelMsg {
  static const open = 0x90; // viewer -> host: {id, port}
  static const result = 0x91; // host -> viewer: {id, ok, err?}
  static const data = 0x92; // both: [type][u32 id][bytes]
  static const close = 0x93; // both: [type][u32 id]
  static const adbInfoRequest = 0x94; // viewer -> host
  static const adbInfo = 0x95; // host -> viewer: {allowed, wireless, connect: [ports], pairing: [ports], legacy?}
  static bool isTunnel(int t) => t >= 0x90 && t <= 0x95;
}

const int _chunk = 32 * 1024;

Uint8List _dataMsg(int id, List<int> bytes, int off, int len) {
  final m = Uint8List(5 + len);
  m[0] = TunnelMsg.data;
  ByteData.sublistView(m).setUint32(1, id, Endian.little);
  m.setRange(5, 5 + len, bytes, off);
  return m;
}

Uint8List _closeMsg(int id) {
  final m = Uint8List(5);
  m[0] = TunnelMsg.close;
  ByteData.sublistView(m).setUint32(1, id, Endian.little);
  return m;
}

Uint8List _json(int type, Map<String, Object?> j) => Uint8List.fromList([type, ...utf8.encode(jsonEncode(j))]);
Map<String, dynamic> _body(Uint8List m) => (jsonDecode(utf8.decode(m.sublist(1))) as Map).cast<String, dynamic>();
int _id(Uint8List m) => ByteData.sublistView(m).getUint32(1, Endian.little);

/// One end of the tunnels of a session (shared plumbing for both sides).
abstract class _Ends {
  _Ends(this.send);
  final Future<void> Function(Uint8List) send;
  final Map<int, Socket> _sockets = {};

  /// Pipes [s] into the session; one chunk in flight at a time, so a big transfer
  /// can't swamp the session (the socket is paused while a chunk is being sent).
  void _pump(int id, Socket s) {
    _sockets[id] = s;
    late StreamSubscription<Uint8List> sub;
    sub = s.listen((bytes) {
      sub.pause();
      () async {
        for (var off = 0; off < bytes.length; off += _chunk) {
          final n = bytes.length - off < _chunk ? bytes.length - off : _chunk;
          await send(_dataMsg(id, bytes, off, n));
        }
      }()
          .whenComplete(sub.resume);
    }, onDone: () {
      if (_sockets.remove(id) != null) unawaited(send(_closeMsg(id)));
    }, onError: (_) {
      if (_sockets.remove(id) != null) unawaited(send(_closeMsg(id)));
      s.destroy();
    }, cancelOnError: true);
  }

  void _onData(Uint8List m) => _sockets[_id(m)]?.add(m.sublist(5));

  void _onClose(Uint8List m) {
    final s = _sockets.remove(_id(m));
    if (s == null) return;
    unawaited(s.flush().catchError((_) {}).whenComplete(s.close));
  }

  void closeAll() {
    for (final s in _sockets.values) {
      s.destroy();
    }
    _sockets.clear();
  }
}

/// Host side: opens loopback connections when allowed.
class TunnelHost extends _Ends {
  TunnelHost(super.send, {required this.allowed, required this.adbInfo});
  final bool Function() allowed;
  final Future<Map<String, Object?>> Function() adbInfo;

  /// Returns true if [m] was a tunnel message.
  bool handle(Uint8List m) {
    if (m.isEmpty || !TunnelMsg.isTunnel(m[0])) return false;
    switch (m[0]) {
      case TunnelMsg.open:
        unawaited(_open(_body(m)));
      case TunnelMsg.data:
        _onData(m);
      case TunnelMsg.close:
        _onClose(m);
      case TunnelMsg.adbInfoRequest:
        unawaited(() async {
          final info = allowed() ? await adbInfo() : <String, Object?>{};
          await send(_json(TunnelMsg.adbInfo, {...info, 'allowed': allowed()}));
        }());
    }
    return true;
  }

  Future<void> _open(Map<String, dynamic> j) async {
    final id = j['id'] as int;
    final port = j['port'] as int? ?? 0;
    if (!allowed()) {
      await send(_json(TunnelMsg.result, {'id': id, 'ok': false, 'err': 'not_allowed'}));
      return;
    }
    if (port <= 0 || port > 65535) {
      await send(_json(TunnelMsg.result, {'id': id, 'ok': false, 'err': 'bad_port'}));
      return;
    }
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 5));
      s.setOption(SocketOption.tcpNoDelay, true);
      await send(_json(TunnelMsg.result, {'id': id, 'ok': true}));
      _pump(id, s);
    } catch (e) {
      await send(_json(TunnelMsg.result, {'id': id, 'ok': false, 'err': 'refused'}));
    }
  }
}

/// Viewer side: local listeners that forward to ports on the host.
class TunnelClient extends _Ends {
  TunnelClient(super.send);
  int _nextId = 1;
  final Map<int, Completer<String?>> _pending = {};
  final Map<int, ServerSocket> _listeners = {}; // remote port -> listener
  Completer<Map<String, dynamic>>? _info;

  bool handle(Uint8List m) {
    if (m.isEmpty || !TunnelMsg.isTunnel(m[0])) return false;
    switch (m[0]) {
      case TunnelMsg.result:
        final j = _body(m);
        _pending.remove(j['id'] as int)?.complete(j['ok'] == true ? null : (j['err'] as String? ?? 'refused'));
      case TunnelMsg.data:
        _onData(m);
      case TunnelMsg.close:
        _onClose(m);
      case TunnelMsg.adbInfo:
        final c = _info;
        _info = null;
        c?.complete(_body(m));
    }
    return true;
  }

  Future<Map<String, dynamic>> adbInfo() {
    final c = _info ??= Completer<Map<String, dynamic>>();
    unawaited(send(Uint8List.fromList([TunnelMsg.adbInfoRequest])));
    return c.future.timeout(const Duration(seconds: 14), onTimeout: () {
      _info = null;
      return {'err': 'timeout'};
    });
  }

  /// Listens on 127.0.0.1 and forwards every connection to [remotePort] on the host.
  /// Returns the local port (the same one again for the same remote port).
  Future<int> forward(int remotePort) async {
    final existing = _listeners[remotePort];
    if (existing != null) return existing.port;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _listeners[remotePort] = server;
    server.listen((local) async {
      local.setOption(SocketOption.tcpNoDelay, true);
      final id = _nextId++;
      final c = Completer<String?>();
      _pending[id] = c;
      await send(_json(TunnelMsg.open, {'id': id, 'port': remotePort}));
      final err = await c.future.timeout(const Duration(seconds: 10), onTimeout: () => 'timeout');
      if (err != null) {
        local.destroy();
        return;
      }
      _pump(id, local);
    });
    return server.port;
  }

  @override
  void closeAll() {
    super.closeAll();
    for (final l in _listeners.values) {
      l.close();
    }
    _listeners.clear();
    for (final c in _pending.values) {
      c.complete('closed');
    }
    _pending.clear();
  }
}
