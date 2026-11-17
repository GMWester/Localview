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
import 'totp.dart';
import 'tunnel.dart';

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
      'adb': s.adbOverLocalview,
      'totp': s.totpSecret,
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
  HostService(this.store, {this.externalCapture, this.externalJpeg, this.injector});

  final AppStore store;

  /// Frame source living on the main isolate (Android MediaProjection).
  final Future<RawFrame?> Function()? externalCapture;

  /// Hosts that compress natively (Android): newest frame as JPEG, null if unchanged since `last`.
  final Future<JpegFrame?> Function(int last, int maxSide, int quality)? externalJpeg;

  /// Viewer asked to rotate this device's screen ('portrait' | 'landscape' | 'auto'); returns an error code or null.
  Future<String?> Function(String mode)? onRotate;
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

  /// WebRTC signaling from a connected controller (game mode).
  void Function(int sid, Uint8List msg)? onRtc;
  void Function(int sid)? onSessionEnded;

  /// Capabilities announced to controllers.
  bool rtcCapable = false;
  bool padsCapable = false;
  bool vrCapable = false;

  void sendRtc(int sid, Uint8List msg) => _toIso?.send(['rtcSend', sid, msg]);

  /// Stop/resume the compatibility (tile) stream while game mode video flows.
  void pauseTiles(int sid, bool paused) => _toIso?.send(['pauseTiles', sid, paused]);
  Future<void> Function(int sid, String name, String url, String volume)? onMount;
  Future<void> Function(int sid)? onUnmount;
  Future<String?> Function()? onClipboardGet;

  /// ADB over Localview: this device's adb ports (Android), for tunnels from viewers.
  Future<Map<String, Object?>> Function()? onAdbInfo;

  Future<void> start() async {
    if (_iso != null) return;
    error = null;
    final rx = ReceivePort();
    _rx = rx;
    final ready = Completer<void>();
    rx.listen((m) => _onMessage(m as List, ready));
    _iso = await Isolate.spawn(_hostIsolateMain, [rx.sendPort, _cfg(), externalCapture != null],
        debugName: 'localview-host');
    store.addListener(_pushConfig);
    await ready.future.timeout(const Duration(seconds: 10), onTimeout: () {});
    notifyListeners();
  }

  /// This computer can silence its speakers while the sound plays on a viewer.
  bool audioRouteCapable = false;
  /// The sound is sent as PCM over the session (Android hosts) instead of WebRTC.
  bool pcmAudioCapable = false;

  Map<String, Object?> _cfg() => {...hostConfigFrom(store, _publicIp), 'jpeg': externalJpeg != null, 'rotate': onRotate != null, 'audioRoute': audioRouteCapable, 'pcmAudio': pcmAudioCapable, 'rtc': rtcCapable, 'pads': padsCapable, 'vr': vrCapable};
  void _pushConfig() => _toIso?.send(['config', _cfg()]);

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
          final mon = m.length > 2 && m[2] != null ? MonitorInfo.fromJson(m[2] as Map) : null;
          injector?.inject(InputEvent.fromList(m[1] as List<Object?>), monitor: mon);
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
        onSessionEnded?.call(m[1] as int);
        notifyListeners();
      case 'rtc':
        onRtc?.call(m[1] as int, m[2] as Uint8List);
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
      case 'grabJpeg':
        JpegFrame? j;
        try {
          j = await externalJpeg?.call(m[2] as int, m[3] as int, m[4] as int);
        } catch (e) {
          debugPrint('jpeg capture failed: $e');
        }
        _toIso?.send(['jpeg', m[1], if (j != null) ...[j.seq, j.width, j.height, TransferableTypedData.fromList([j.jpeg])]]);
      case 'rotate':
        String? err;
        try {
          final rotate = onRotate;
          err = rotate == null ? 'unsupported' : await rotate(m[2] as String);
        } catch (e) {
          err = '$e';
        }
        _toIso?.send(['rotateResult', m[1], err]);
      case 'adbInfo':
        Map<String, Object?> info = const {};
        try {
          info = await onAdbInfo?.call() ?? const {};
        } catch (e) {
          debugPrint('adb info failed: $e');
        }
        _toIso?.send(['adbInfoResult', m[1], info]);
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
  final Map<int, Completer<Map<String, Object?>>> _adbInfos = {};
  final Map<int, Completer<JpegFrame?>> _jpegs = {};
  final Map<int, Completer<String?>> _rotates = {};

  Future<JpegFrame?> grabJpeg(int last, int maxSide, int quality) {
    final id = _nextGrab++;
    final c = Completer<JpegFrame?>();
    _jpegs[id] = c;
    toMain.send(['grabJpeg', id, last, maxSide, quality]);
    return c.future.timeout(const Duration(seconds: 5), onTimeout: () {
      _jpegs.remove(id);
      return null;
    });
  }

  Future<String?> rotate(String mode) {
    final id = _nextGrab++;
    final c = Completer<String?>();
    _rotates[id] = c;
    toMain.send(['rotate', id, mode]);
    return c.future.timeout(const Duration(seconds: 10), onTimeout: () => 'timeout');
  }

  Future<Map<String, Object?>> adbInfo() {
    final id = _nextGrab++;
    final c = Completer<Map<String, Object?>>();
    _adbInfos[id] = c;
    toMain.send(['adbInfo', id]);
    return c.future.timeout(const Duration(seconds: 8), onTimeout: () => const {});
  }
  final Map<String, List<DateTime>> _failures = {};
  final Set<int> _usedTotpSteps = {};

  /// Session tickets: extra windows of an authenticated viewer connect with these instead of
  /// the password / authenticator code. In memory only; cleared when the login settings change.
  final Map<String, ({Uint8List key, String peerId, bool viaPairKey, DateTime expires})> _tickets = {};

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
        final old = cfg;
        cfg = (m[1] as Map).cast<String, Object?>();
        if (!listEquals(old['verifier'] as Uint8List?, cfg['verifier'] as Uint8List?) ||
            !listEquals(old['totp'] as Uint8List?, cfg['totp'] as Uint8List?)) {
          _tickets.clear();
        }
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
      case 'jpeg':
        final c = _jpegs.remove(m[1] as int);
        if (c != null) {
          c.complete(m.length < 6
              ? null
              : JpegFrame(m[2] as int, m[3] as int, m[4] as int, (m[5] as TransferableTypedData).materialize().asUint8List()));
        }
      case 'rotateResult':
        _rotates.remove(m[1] as int)?.complete(m[2] as String?);
      case 'adbInfoResult':
        _adbInfos.remove(m[1] as int)?.complete((m[2] as Map).cast<String, Object?>());
      case 'kickAll':
        _kickAll();
      case 'rtcSend':
        _sessions[m[1] as int]?.sendMsg(m[2] as Uint8List);
      case 'pauseTiles':
        _sessions[m[1] as int]?.video = !(m[2] as bool);
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

  Future<RawFrame?> grab([MonitorInfo? monitor]) async {
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
    return _capturer?.capture(monitor: monitor);
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
      } else if (mode == 'ticket') {
        _tickets.removeWhere((_, t) => t.expires.isBefore(DateTime.now()));
        final t = _tickets[hello['tid'] as String? ?? ''];
        if (t == null || t.peerId != peerId) {
          _recordFailure(ip);
          return reject('bad_ticket');
        }
        secret = t.key;
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
        'totp': cfg['totp'] != null,
      })));
      final ecdh = await eph.agree(base64Decode(hello['eph'] as String));
      final keys = await deriveSessionKeys(
          ecdh: ecdh, secret: secret, nonceClient: base64Decode(hello['nonce'] as String), nonceHost: nonceH);
      final ch = SecureChannel(sendKey: keys.h2c, recvKey: keys.c2h, isClient: false);
      Map auth;
      try {
        // With 2FA the user types the authenticator code first: allow time for that.
        final authTimeout = Duration(seconds: cfg['totp'] != null ? 180 : 20);
        auth = jsonDecode(utf8.decode(await ch.open(await sock.next(timeout: authTimeout)))) as Map;
        if (auth['t'] != 'auth') throw const DecryptError();
      } on DecryptError {
        _recordFailure(ip);
        return reject(switch (mode) { 'password' => 'bad_password', 'ticket' => 'bad_ticket', _ => 'bad_key' });
      }
      final ticket = mode == 'ticket' ? _tickets[hello['tid'] as String] : null;
      final totpSecret = cfg['totp'] as Uint8List?;
      // A ticket was issued after a full login (including the authenticator code).
      if (totpSecret != null && ticket == null) {
        final step = await totpVerify(totpSecret, auth['totp'] as String? ?? '');
        // A code is accepted once: replaying an observed code is refused.
        if (step == null || _usedTotpSteps.contains(step)) {
          _recordFailure(ip);
          return reject(step == null ? 'bad_totp' : 'totp_reused');
        }
        _usedTotpSteps.add(step);
        _usedTotpSteps.removeWhere((s) => s < step - 4);
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
      final viaPairKey = ticket?.viaPairKey ?? mode == 'paired';
      final session = _HostSession(this, sid, sock, ch, peerId, viaPairKey);
      session._monitorId = auth['monitor'] as String?;
      // Native JPEG frames for viewers that understand them (1.7.0+); older ones get pixel tiles.
      session._jpeg = cfg['jpeg'] == true && auth['jpeg'] == true;
      String? tid = mode == 'ticket' ? hello['tid'] as String : null;
      if (tid == null) {
        tid = base64UrlEncode(randomBytes(16));
        _tickets[tid] = (key: randomBytes(32), peerId: peerId, viaPairKey: viaPairKey, expires: DateTime.now().add(const Duration(hours: 12)));
      }
      final issued = _tickets[tid]!;
      session.files = FileLink(send: session.sendMsg, root: cfg['fsRoot'] as String?, share: cfg['share'] == true);
      _sessions[sid] = session;
      await session.sendMsg(jsonMsg(0x00, {
        't': 'welcome',
        'id': cfg['id'],
        'name': cfg['name'],
        'os': cfg['os'],
        'share': cfg['share'] == true,
        'rtc': cfg['rtc'] == true,
        'pads': cfg['pads'] == true,
        'vr': cfg['vr'] == true,
        'adb': cfg['adb'] == true,
        'rotate': cfg['rotate'] == true,
        'audioRoute': cfg['audioRoute'] == true && (cfg['rtc'] == true || cfg['pcmAudio'] == true),
        'pcmAudio': cfg['pcmAudio'] == true,
        if (cfg['publicIp'] != null) 'publicIp': cfg['publicIp'],
        'port': cfg['port'],
        if (newKey != null) 'pairKey': base64Encode(newKey),
        'ticket': {'id': tid, 'key': base64Encode(issued.key)},
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
  late final TunnelHost tunnels =
      TunnelHost(sendMsg, allowed: () => host.cfg['adb'] == true, adbInfo: host.adbInfo);
  bool video = true;
  Future<void> _sendChain = Future.value();
  int _inFlight = 0;
  bool _closed = false;
  late double scale = (host.cfg['scale'] as num?)?.toDouble() ?? 1.0;
  late int fps = (host.cfg['fps'] as int?) ?? 30;
  Completer<void>? _ackWaiter;

  /// Monitors of this host and the one this viewer watches (each viewer chooses its own).
  List<MonitorInfo> _monitors = const [];
  bool _jpeg = false;
  int _jpegSeq = -1;
  String? _monitorId;
  MonitorInfo? get _monitor => pickMonitor(_monitors, _monitorId);
  DateTime _monitorsAt = DateTime(0);

  Future<void> _refreshMonitors({bool force = false}) async {
    if (host.externalCapture) return;
    final now = DateTime.now();
    if (!force && now.difference(_monitorsAt) < const Duration(seconds: 3)) return;
    _monitorsAt = now;
    final l = listMonitors();
    if (!force && listEquals(l, _monitors)) return;
    _monitors = l;
    if (l.isEmpty) return;
    await sendMsg(jsonMsg(Msg.monitors, {'list': [for (final m in l) m.toJson()], 'current': _monitor?.id}));
  }

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
    tunnels.closeAll();
  }

  Future<void> run() async {
    await _refreshMonitors(force: true);
    unawaited(_frameLoop());
    try {
      while (!_closed) {
        final m = await ch.open(await sock.next(timeout: const Duration(seconds: 30)));
        if (m.isEmpty || files.handle(m) || tunnels.handle(m)) continue;
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
            _jpegSeq = -1;
          case Msg.rotate:
            final mode = jsonBody(m)['mode'] as String? ?? 'auto';
            final err = await host.rotate(mode);
            await sendMsg(jsonMsg(Msg.rotateResult, {'mode': mode, 'error': ?err}));
            _jpegSeq = -1;
          case Msg.selectMonitor:
            _monitorId = jsonBody(m)['id'] as String?;
            encoder.reset();
            await _refreshMonitors(force: true);
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
          case final t when Msg.isRtc(t) || Msg.isVr(t):
            host.toMain.send(['rtc', id, m]);
          default:
            final e = InputEvent.decode(m);
            if (e != null) host.toMain.send(['input', e.toList(), _monitor?.toJson()]);
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
      final gap = idleFrames > 30 && !_jpeg ? (minGap < 200 ? 200 : minGap) : minGap;
      if (elapsed < gap) await Future<void>.delayed(Duration(milliseconds: gap - elapsed));
      sw.reset();
      if (_jpeg) {
        // Android: the newest frame, JPEG-compressed natively; nothing is sent while the screen is still.
        final j = await host.grabJpeg(_jpegSeq, (1440 * scale).round(), 70);
        if (_closed) break;
        if (j == null) {
          idleFrames++;
          continue;
        }
        idleFrames = 0;
        _jpegSeq = j.seq;
        if (j.width != lastW || j.height != lastH) {
          lastW = j.width;
          lastH = j.height;
          await sendMsg(jsonMsg(Msg.screenInfo, {'w': j.width, 'h': j.height}));
        }
        _inFlight++;
        final msg = Uint8List(j.jpeg.length + 1)
          ..[0] = Msg.frameJpeg
          ..setRange(1, j.jpeg.length + 1, j.jpeg);
        await sendMsg(msg);
        continue;
      }
      await _refreshMonitors();
      final f = await host.grab(_monitor);
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
