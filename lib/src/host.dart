import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'codec.dart';
import 'config.dart';
import 'crypto.dart';
import 'link.dart';
import 'net.dart';
import 'platform/platform.dart';
import 'protocol.dart';
import 'storage.dart';

/// Snapshot of what the host isolate needs from [AppStore].
Map<String, Object?> hostConfigFrom(AppStore s, [String? publicIp]) => {
      'publicIp': publicIp,
      'id': s.deviceId,
      'name': s.deviceName,
      'os': kOsName,
      'port': s.tcpPort,
      'enabled': s.hostEnabled,
      'salt': s.passwordSalt,
      'verifier': s.passwordVerifier,
      'scale': s.streamScale,
      'fps': s.maxFps,
      'share': s.shareFiles,
      'mount': s.mountDrives,
      'fsRoot': s.fsRoot,
      'trusted': [
        for (final p in s.paired)
          if (p.allowIncoming) {'id': p.id, 'key': p.key}
      ],
    };

class HostSessionInfo {
  HostSessionInfo(this.id, this.peerName, this.peerOs, this.address);
  final int id;
  final String peerName, peerOs, address;
}

/// Main-isolate side of the host (the device being controlled).
class HostService extends ChangeNotifier {
  HostService(this.store, {this.externalCapture, this.injector});

  final AppStore store;

  /// Frame source living on the main isolate (Android MediaProjection).
  final Future<RawFrame?> Function()? externalCapture;
  final InputInjector? injector;

  Isolate? _iso;
  SendPort? _toIso;
  ReceivePort? _rx;
  final Map<int, HostSessionInfo> sessions = {};
  String? error;
  bool get running => _iso != null && boundPort != null;

  /// Router-reported public IP (WAN/combined), shared with peers that pair.
  String? _publicIp;
  String? get publicIp => _publicIp;
  set publicIp(String? v) {
    _publicIp = v;
    _pushConfig();
  }
  int? boundPort;
  void Function(String text)? onClipboardSet;
  Future<void> Function(int sid, String name, String url, String volume)? onMount;
  Future<void> Function(int sid)? onUnmount;
  Future<String?> Function()? onClipboardGet;

  Future<void> start() async {
    if (_iso != null) return;
    error = null;
    final rx = ReceivePort();
    _rx = rx;
    final ready = Completer<void>();
    rx.listen((m) => _onMessage(m as List, ready));
    _iso = await Isolate.spawn(_hostIsolateMain, [rx.sendPort, hostConfigFrom(store, _publicIp), externalCapture != null],
        debugName: 'localview-host');
    store.addListener(_pushConfig);
    await ready.future.timeout(const Duration(seconds: 10), onTimeout: () {});
    notifyListeners();
  }

  void _pushConfig() => _toIso?.send(['config', hostConfigFrom(store, _publicIp)]);

  Future<void> stop() async {
    store.removeListener(_pushConfig);
    _toIso?.send(['stop']);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _iso?.kill(priority: Isolate.immediate);
    _iso = null;
    _toIso = null;
    _rx?.close();
    _rx = null;
    sessions.clear();
    boundPort = null;
    notifyListeners();
  }

  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<void> _onMessage(List m, Completer<void> ready) async {
    switch (m[0]) {
      case 'ready':
        _toIso = m[1] as SendPort;
        boundPort = m[2] as int?;
        error = m[3] as String?;
        if (!ready.isCompleted) ready.complete();
        notifyListeners();
      case 'input':
        try {
          injector?.inject(InputEvent.fromList(m[1] as List<Object?>));
        } catch (e) {
          debugPrint('inject failed: $e');
        }
      case 'grab':
        final req = m[1] as int;
        RawFrame? f;
        try {
          f = await externalCapture?.call();
        } catch (e) {
          debugPrint('capture failed: $e');
        }
        _toIso?.send([
          'frame',
          req,
          if (f != null) ...[f.width, f.height, f.stride, f.format, TransferableTypedData.fromList([f.pixels])]
        ]);
      case 'session+':
        sessions[m[1] as int] = HostSessionInfo(m[1] as int, m[2] as String, m[3] as String, m[4] as String);
        notifyListeners();
      case 'session-':
        sessions.remove(m[1] as int);
        notifyListeners();
      case 'paired':
        final j = (m[1] as Map).cast<String, Object?>();
        await store.upsertPaired(PairedDevice(
          id: j['id'] as String,
          name: j['name'] as String,
          os: j['os'] as String,
          address: j['address'] as String,
          port: kDefaultTcpPort,
          key: j['key'] as Uint8List,
          allowIncoming: true,
          outgoing: store.findPaired(j['id'] as String)?.outgoing ?? false,
        ));
      case 'mount':
        await onMount?.call(m[1] as int, m[2] as String, m[3] as String, m[4] as String);
      case 'unmount':
        await onUnmount?.call(m[1] as int);
      case 'clipSet':
        onClipboardSet?.call(m[1] as String);
      case 'clipGet':
        final t = await onClipboardGet?.call();
        _toIso?.send(['clip', m[1], t ?? '']);
      case 'log':
        debugPrint('host: ${m[1]}');
    }
  }

  void disconnectAll() => _toIso?.send(['kickAll']);
}

// ---------------------------------------------------------------------------
// Host isolate
// ---------------------------------------------------------------------------

Future<void> _hostIsolateMain(List args) async {
  final toMain = args[0] as SendPort;
  final h = _HostIsolate(toMain, (args[1] as Map).cast<String, Object?>(), args[2] as bool);
  await h.run();
}

class _HostIsolate {
  _HostIsolate(this.toMain, this.cfg, this.externalCapture);

  final SendPort toMain;
  Map<String, Object?> cfg;
  final bool externalCapture;
  final rx = ReceivePort();
  ServerSocket? _server;
  final Map<int, _HostSession> _sessions = {};
  int _nextSession = 1;
  ScreenCapturer? _capturer;
  int _nextGrab = 1;
  final Map<int, Completer<RawFrame?>> _grabs = {};
  final Map<int, Completer<String>> _clips = {};
  final Map<String, List<DateTime>> _failures = {};

  Future<void> run() async {
    rx.listen((m) => _onMain(m as List));
    String? err;
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv6, cfg['port'] as int, v6Only: false);
    } catch (_) {
      try {
        _server = await ServerSocket.bind(InternetAddress.anyIPv4, cfg['port'] as int);
      } catch (e) {
        err = 'Could not listen on port ${cfg['port']}: $e';
      }
    }
    toMain.send(['ready', rx.sendPort, _server?.port, err]);
    _server?.listen((s) => _accept(s));
  }

  void _onMain(List m) {
    switch (m[0]) {
      case 'config':
        cfg = (m[1] as Map).cast<String, Object?>();
        if (cfg['enabled'] != true) _kickAll();
        for (final s in _sessions.values) {
          s.revalidate();
        }
      case 'frame':
        final c = _grabs.remove(m[1] as int);
        if (c == null) return;
        if (m.length < 7) {
          c.complete(null);
        } else {
          final px = (m[6] as TransferableTypedData).materialize().asUint8List();
          c.complete(RawFrame(m[2] as int, m[3] as int, m[4] as int, px, m[5] as int));
        }
      case 'clip':
        _clips.remove(m[1] as int)?.complete(m[2] as String);
      case 'kickAll':
        _kickAll();
      case 'stop':
        _kickAll();
        _server?.close();
        _capturer?.dispose();
        rx.close();
    }
  }

  void _kickAll() {
    for (final s in _sessions.values.toList()) {
      s.close();
    }
  }

  Future<RawFrame?> grab() async {
    if (externalCapture) {
      final id = _nextGrab++;
      final c = Completer<RawFrame?>();
      _grabs[id] = c;
      toMain.send(['grab', id]);
      return c.future.timeout(const Duration(seconds: 5), onTimeout: () {
        _grabs.remove(id);
        return null;
      });
    }
    _capturer ??= createScreenCapturer();
    return _capturer?.capture();
  }

  Future<String> clipboardGet() {
    final id = _nextGrab++;
    final c = Completer<String>();
    _clips[id] = c;
    toMain.send(['clipGet', id]);
    return c.future.timeout(const Duration(seconds: 3), onTimeout: () => '');
  }

  bool _lockedOut(String ip) {
    final now = DateTime.now();
    final l = _failures[ip]?..removeWhere((t) => now.difference(t) > const Duration(minutes: 5));
    return l != null && l.length >= 5;
  }

  void _recordFailure(String ip) => (_failures[ip] ??= []).add(DateTime.now());

  Future<void> _accept(Socket raw) async {
    final sock = FramedSocket(raw);
    final ip = raw.remoteAddress.address.replaceFirst('::ffff:', '');
    void reject(String code) {
      sock.send(utf8.encode(jsonEncode({'t': 'error', 'error': code})));
      sock.close();
    }

    try {
      final hello = jsonDecode(utf8.decode(await sock.next(timeout: const Duration(seconds: 15)))) as Map;
      if (hello['t'] != 'hello') return reject('protocol');
      if ((hello['v'] as int? ?? 0) != kProtocolVersion) return reject('version');
      if (cfg['enabled'] != true) return reject('host_disabled');
      if (_lockedOut(ip)) return reject('locked_out');
      final mode = hello['mode'] as String?;
      final peerId = hello['id'] as String? ?? '';
      Uint8List secret;
      Uint8List? salt;
      if (mode == 'password') {
        final v = cfg['verifier'] as Uint8List?;
        if (v == null) return reject('no_password');
        secret = v;
        salt = cfg['salt'] as Uint8List;
      } else if (mode == 'paired') {
        final t = (cfg['trusted'] as List).cast<Map>().where((t) => t['id'] == peerId).toList();
        if (t.isEmpty) return reject('not_paired');
        secret = t.first['key'] as Uint8List;
      } else {
        return reject('protocol');
      }
      final eph = await EphemeralKeys.create();
      final nonceH = randomBytes(16);
      sock.send(utf8.encode(jsonEncode({
        't': 'hello_ack',
        'id': cfg['id'],
        'name': cfg['name'],
        'os': cfg['os'],
        'eph': base64Encode(eph.publicKey),
        'nonce': base64Encode(nonceH),
        if (salt != null) 'salt': base64Encode(salt),
      })));
      final ecdh = await eph.agree(base64Decode(hello['eph'] as String));
      final keys = await deriveSessionKeys(
          ecdh: ecdh, secret: secret, nonceClient: base64Decode(hello['nonce'] as String), nonceHost: nonceH);
      final ch = SecureChannel(sendKey: keys.h2c, recvKey: keys.c2h, isClient: false);
      Map auth;
      try {
        auth = jsonDecode(utf8.decode(await ch.open(await sock.next(timeout: const Duration(seconds: 20))))) as Map;
        if (auth['t'] != 'auth') throw const DecryptError();
      } on DecryptError {
        _recordFailure(ip);
        return reject(mode == 'password' ? 'bad_password' : 'bad_key');
      }
      Uint8List? newKey;
      if (auth['pair'] == true && mode == 'password') {
        newKey = randomBytes(32);
        toMain.send([
          'paired',
          {'id': peerId, 'name': hello['name'] ?? 'Device', 'os': hello['os'] ?? '', 'address': ip, 'key': newKey}
        ]);
      }
      final sid = _nextSession++;
      final session = _HostSession(this, sid, sock, ch, peerId, mode == 'paired');
      session.files = FileLink(send: session.sendMsg, root: cfg['fsRoot'] as String?, share: cfg['share'] == true);
      _sessions[sid] = session;
      await session.sendMsg(jsonMsg(0x00, {
        't': 'welcome',
        'id': cfg['id'],
        'name': cfg['name'],
        'os': cfg['os'],
        'share': cfg['share'] == true,
        if (cfg['publicIp'] != null) 'publicIp': cfg['publicIp'],
        'port': cfg['port'],
        if (newKey != null) 'pairKey': base64Encode(newKey),
      }).sublist(1));
      toMain.send(['session+', sid, hello['name'] ?? 'Device', hello['os'] ?? '', ip]);
      if (auth['share'] == true && cfg['mount'] == true) {
        try {
          final dav = await session.files.startDav(hello['name'] as String? ?? 'Device');
          toMain.send(['mount', sid, hello['name'] ?? 'Device', dav.url, dav.volumeName]);
        } catch (e) {
          toMain.send(['log', 'drive bridge failed: $e']);
        }
      }
      await session.run();
      _sessions.remove(sid);
      if (session.files.dav != null) toMain.send(['unmount', sid]);
      await session.files.close();
      toMain.send(['session-', sid]);
    } catch (e) {
      toMain.send(['log', 'session from $ip ended: $e']);
      await sock.close();
    }
  }
}

class _HostSession {
  _HostSession(this.host, this.id, this.sock, this.ch, this.peerId, this.viaPairKey);

  final _HostIsolate host;
  final int id;
  final FramedSocket sock;
  final SecureChannel ch;
  final String peerId;
  final bool viaPairKey;
  final FrameEncoder encoder = FrameEncoder();
  late FileLink files;
  bool video = true;
  Future<void> _sendChain = Future.value();
  int _inFlight = 0;
  bool _closed = false;
  late double scale = (host.cfg['scale'] as num?)?.toDouble() ?? 1.0;
  late int fps = (host.cfg['fps'] as int?) ?? 30;
  Completer<void>? _ackWaiter;

  Future<void> sendMsg(Uint8List m) {
    return _sendChain = _sendChain.then((_) async {
      if (_closed) return;
      sock.send(await ch.seal(m));
    });
  }

  void revalidate() {
    if (viaPairKey) {
      final ok = (host.cfg['trusted'] as List).cast<Map>().any((t) => t['id'] == peerId);
      if (!ok) close();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    sock.close();
    _ackWaiter?.complete();
  }

  Future<void> run() async {
    unawaited(_frameLoop());
    try {
      while (!_closed) {
        final m = await ch.open(await sock.next(timeout: const Duration(seconds: 30)));
        if (m.isEmpty || files.handle(m)) continue;
        switch (m[0]) {
          case Msg.ping:
            await sendMsg(Uint8List.fromList([Msg.pong, ...m.sublist(1)]));
          case Msg.frameAck:
            if (_inFlight > 0) _inFlight--;
            final w = _ackWaiter;
            _ackWaiter = null;
            w?.complete();
          case Msg.refresh:
            encoder.reset();
          case Msg.streamSettings:
            final j = jsonBody(m);
            scale = ((j['scale'] as num?)?.toDouble() ?? scale).clamp(0.25, 1.0);
            video = j['video'] as bool? ?? video;
            fps = ((j['fps'] as int?) ?? fps).clamp(1, 60);
            encoder.reset();
          case Msg.clipboard:
            host.toMain.send(['clipSet', textBody(m)]);
          case Msg.clipboardRequest:
            final t = await host.clipboardGet();
            await sendMsg(textMsg(Msg.clipboard, t));
          case Msg.bye:
            close();
          default:
            final e = InputEvent.decode(m);
            if (e != null) host.toMain.send(['input', e.toList()]);
        }
      }
    } catch (_) {
      // connection closed / timeout / tamper
    } finally {
      close();
    }
  }

  Future<void> _frameLoop() async {
    var lastW = -1, lastH = -1;
    final sw = Stopwatch()..start();
    var idleFrames = 0;
    while (!_closed) {
      if (!video) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        continue;
      }
      if (_inFlight >= 2) {
        final w = _ackWaiter ??= Completer<void>();
        await w.future.timeout(const Duration(seconds: 5), onTimeout: () {
          // Peer stopped acking; let it recover.
          _inFlight = 0;
        });
        continue;
      }
      final minGap = 1000 ~/ fps;
      final elapsed = sw.elapsedMilliseconds;
      // Back off to ~5 fps polling when the screen is static.
      final gap = idleFrames > 30 ? (minGap < 200 ? 200 : minGap) : minGap;
      if (elapsed < gap) await Future<void>.delayed(Duration(milliseconds: gap - elapsed));
      sw.reset();
      final f = await host.grab();
      if (_closed) break;
      if (f == null) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        continue;
      }
      if (f.width != lastW || f.height != lastH) {
        lastW = f.width;
        lastH = f.height;
        encoder.reset();
        await sendMsg(jsonMsg(Msg.screenInfo, {'w': f.width, 'h': f.height}));
      }
      final msg = encoder.encode(f, scale: scale);
      if (msg == null) {
        idleFrames++;
        continue;
      }
      idleFrames = 0;
      _inFlight++;
      await sendMsg(msg);
    }
  }
}
