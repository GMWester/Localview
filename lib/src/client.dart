import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'codec.dart';
import 'config.dart';
import 'crypto.dart';
import 'files.dart';
import 'link.dart';
import 'net.dart';
import 'protocol.dart';

String describeError(String code) => switch (code) {
      'bad_password' => 'Wrong password.',
      'bad_key' => 'The pairing key was rejected. Remove the device and add it again.',
      'not_paired' => 'That device no longer trusts this one. Remove it and add it again with its password.',
      'no_password' => 'The other device has not set a password yet.',
      'host_disabled' => 'Remote control is turned off on the other device.',
      'locked_out' => 'Too many wrong passwords. Try again in 5 minutes.',
      'version' => 'The other device runs an incompatible Localview version.',
      'wrong_device' => 'A different device answered at that address.',
      _ => code,
    };

class ConnectParams {
  ConnectParams({
    required this.host,
    required this.port,
    this.password,
    this.pairKey,
    this.wantPair = false,
    this.expectedId,
    required this.myId,
    required this.myName,
    this.share = true,
    this.fsRoot,
    this.mount = true,
    this.scale = 1.0,
    this.fps = 30,
    this.video = true,
  });
  final String host;
  final int port;
  final String? password;
  final Uint8List? pairKey;
  final bool wantPair;
  final String? expectedId;
  final String myId, myName;
  final bool share;
  final String? fsRoot;
  final bool mount;
  final double scale;
  final int fps;
  final bool video;

  Map<String, Object?> toMap() => {
        'host': host,
        'port': port,
        'password': password,
        'pairKey': pairKey,
        'wantPair': wantPair,
        'expectedId': expectedId,
        'myId': myId,
        'myName': myName,
        'os': kOsName,
        'share': share,
        'fsRoot': fsRoot,
        'mount': mount,
        'scale': scale,
        'fps': fps,
        'video': video,
      };
}

/// Main-isolate handle for an outgoing connection (this device controls the peer).
class ClientSession extends ChangeNotifier {
  ClientSession._(this.params);

  final ConnectParams params;
  Isolate? _iso;
  SendPort? _toIso;
  final ReceivePort _rx = ReceivePort();
  String status = 'Connecting…';
  bool connected = false;
  bool closed = false;
  String? error;
  String peerId = '', peerName = '', peerOs = '';
  bool peerShares = false;
  Uint8List? newPairKey;
  int screenW = 0, screenH = 0;
  final ValueNotifier<ui.Image?> image = ValueNotifier(null);
  String? mountUrl, mountVolume;
  void Function(String)? onClipboard;
  Future<void> Function(String url, String volume)? onMount;
  Future<void> Function()? onUnmount;
  final Completer<void> _handshake = Completer();
  int _nextFs = 1;
  final Map<int, Completer<({Map<String, dynamic> json, Uint8List data})>> _fs = {};

  static Future<ClientSession> connect(ConnectParams p,
      {Future<void> Function(String url, String volume)? onMount, Future<void> Function()? onUnmount}) async {
    final s = ClientSession._(p)
      ..onMount = onMount
      ..onUnmount = onUnmount;
    s._rx.listen((m) => s._onMessage(m as List));
    s._iso = await Isolate.spawn(_clientIsolateMain, [s._rx.sendPort, p.toMap()], debugName: 'localview-client');
    await s._handshake.future;
    if (s.error != null) throw Exception(s.error);
    return s;
  }

  Future<void> _onMessage(List m) async {
    switch (m[0]) {
      case 'port':
        _toIso = m[1] as SendPort;
      case 'status':
        status = m[1] as String;
        notifyListeners();
      case 'connected':
        final j = (m[1] as Map).cast<String, Object?>();
        peerId = j['id'] as String? ?? '';
        peerName = j['name'] as String? ?? '';
        peerOs = j['os'] as String? ?? '';
        peerShares = j['share'] == true;
        newPairKey = j['pairKey'] as Uint8List?;
        connected = true;
        status = 'Connected';
        if (!_handshake.isCompleted) _handshake.complete();
        notifyListeners();
      case 'screen':
        screenW = m[1] as int;
        screenH = m[2] as int;
        notifyListeners();
      case 'frame':
        final w = m[1] as int, h = m[2] as int, fmt = m[3] as int;
        final px = (m[4] as TransferableTypedData).materialize().asUint8List();
        ui.decodeImageFromPixels(px, w, h, fmt == PixelFmt.bgra ? ui.PixelFormat.bgra8888 : ui.PixelFormat.rgba8888,
            (img) {
          final old = image.value;
          image.value = img;
          old?.dispose();
          _toIso?.send(['shown']);
        });
      case 'clip':
        onClipboard?.call(m[1] as String);
      case 'mount':
        mountUrl = m[1] as String;
        mountVolume = m[2] as String;
        try {
          await onMount?.call(mountUrl!, mountVolume!);
        } catch (e) {
          debugPrint('mount failed: $e');
        }
        notifyListeners();
      case 'fsr':
        final data = m[3] == null ? Uint8List(0) : (m[3] as TransferableTypedData).materialize().asUint8List();
        _fs.remove(m[1] as int)?.complete((json: (m[2] as Map).cast<String, dynamic>(), data: data));
      case 'error':
        error = describeError(m[1] as String);
        if (!_handshake.isCompleted) _handshake.complete();
        notifyListeners();
      case 'closed':
        await _finish();
    }
  }

  Future<void> _finish() async {
    if (closed) return;
    closed = true;
    connected = false;
    if (!_handshake.isCompleted) {
      error ??= 'Connection failed.';
      _handshake.complete();
    }
    for (final c in _fs.values) {
      c.completeError(FsException('disconnected'));
    }
    _fs.clear();
    if (mountUrl != null) {
      try {
        await onUnmount?.call();
      } catch (_) {}
      mountUrl = null;
    }
    _rx.close();
    _iso?.kill(priority: Isolate.beforeNextEvent);
    notifyListeners();
  }

  void send(Uint8List msg) => _toIso?.send(['send', msg]);
  void setStream({double? scale, int? fps, bool? video}) => send(jsonMsg(Msg.streamSettings, {
        'scale': ?scale,
        'fps': ?fps,
        'video': ?video,
      }));
  void sendClipboard(String text) => send(textMsg(Msg.clipboard, text));
  void requestClipboard() => send(Uint8List.fromList([Msg.clipboardRequest]));

  /// File operations on the peer, used by the in-app file browser.
  late final FsClient files = FsClient((req) async {
    final r = decodeFs(req);
    final c = Completer<({Map<String, dynamic> json, Uint8List data})>();
    final id = _nextFs++;
    _fs[id] = c;
    _toIso?.send(['fs', id, r.json, TransferableTypedData.fromList([r.data])]);
    final res = await c.future;
    files.onResponse(encodeFs(kFsResp, r.id, res.json, res.data));
  });

  Future<void> close() async {
    _toIso?.send(['close']);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await _finish();
  }
}

// ---------------------------------------------------------------------------
// Client isolate
// ---------------------------------------------------------------------------

Future<void> _clientIsolateMain(List args) async {
  final toMain = args[0] as SendPort;
  final p = (args[1] as Map).cast<String, Object?>();
  final rx = ReceivePort();
  toMain.send(['port', rx.sendPort]);
  FramedSocket? sock;
  SecureChannel? ch;
  FileLink? link;
  Future<void> chain = Future.value();
  var closing = false;

  Future<void> sendMsg(Uint8List m) => chain = chain.then((_) async {
        if (sock == null || ch == null || sock.isClosed) return;
        sock.send(await ch.seal(m));
      });

  final decoder = FrameDecoder();
  var dirty = false, waitingShown = false;
  void post() {
    final fb = decoder.fb;
    if (fb == null) return;
    dirty = false;
    waitingShown = true;
    toMain.send(['frame', decoder.width, decoder.height, decoder.format, TransferableTypedData.fromList([fb])]);
  }

  rx.listen((m) async {
    m as List;
    switch (m[0]) {
      case 'send':
        await sendMsg(m[1] as Uint8List);
      case 'shown':
        waitingShown = false;
        if (dirty) post();
      case 'fs':
        final id = m[1] as int;
        final data = (m[3] as TransferableTypedData).materialize().asUint8List();
        try {
          final r = await link!.client.raw((m[2] as Map).cast<String, Object?>(), data);
          toMain.send(['fsr', id, r.json, TransferableTypedData.fromList([r.data])]);
        } on FsException catch (e) {
          toMain.send(['fsr', id, {'ok': false, 'err': e.code}, null]);
        } catch (e) {
          toMain.send(['fsr', id, {'ok': false, 'err': 'io'}, null]);
        }
      case 'close':
        closing = true;
        await sendMsg(Uint8List.fromList([Msg.bye]));
        await chain;
        await sock?.close();
    }
  });

  try {
    toMain.send(['status', 'Connecting to ${p['host']}…']);
    final raw = await Socket.connect(p['host'] as String, p['port'] as int, timeout: const Duration(seconds: 10));
    sock = FramedSocket(raw);
    final eph = await EphemeralKeys.create();
    final nonceC = randomBytes(16);
    final usePassword = p['password'] != null;
    sock.send(utf8.encode(jsonEncode({
      't': 'hello',
      'v': kProtocolVersion,
      'mode': usePassword ? 'password' : 'paired',
      'id': p['myId'],
      'name': p['myName'],
      'os': p['os'],
      'eph': base64Encode(eph.publicKey),
      'nonce': base64Encode(nonceC),
    })));
    final ack = jsonDecode(utf8.decode(await sock.next(timeout: const Duration(seconds: 15)))) as Map;
    if (ack['t'] == 'error') throw _Remote(ack['error'] as String);
    if (ack['t'] != 'hello_ack') throw _Remote('protocol');
    if (p['expectedId'] != null && ack['id'] != p['expectedId']) throw _Remote('wrong_device');
    Uint8List secret;
    if (usePassword) {
      toMain.send(['status', 'Verifying password…']);
      secret = await derivePasswordKey(p['password'] as String, base64Decode(ack['salt'] as String));
    } else {
      secret = p['pairKey'] as Uint8List;
    }
    final ecdh = await eph.agree(base64Decode(ack['eph'] as String));
    final keys =
        await deriveSessionKeys(ecdh: ecdh, secret: secret, nonceClient: nonceC, nonceHost: base64Decode(ack['nonce'] as String));
    ch = SecureChannel(sendKey: keys.c2h, recvKey: keys.h2c, isClient: true);
    await sendMsg(Uint8List.fromList(utf8.encode(jsonEncode({'t': 'auth', 'pair': p['wantPair'] == true, 'share': p['share'] == true}))));
    final wraw = await sock.next(timeout: const Duration(seconds: 20));
    Map welcome;
    try {
      welcome = jsonDecode(utf8.decode(await ch.open(wraw))) as Map;
    } on DecryptError {
      Map? e;
      try {
        e = jsonDecode(utf8.decode(wraw)) as Map;
      } catch (_) {}
      throw _Remote((e?['error'] as String?) ?? 'bad_password');
    }
    link = FileLink(send: sendMsg, root: p['fsRoot'] as String?, share: p['share'] == true);
    toMain.send([
      'connected',
      {
        'id': welcome['id'],
        'name': welcome['name'],
        'os': welcome['os'],
        'share': welcome['share'] == true,
        if (welcome['pairKey'] != null) 'pairKey': base64Decode(welcome['pairKey'] as String),
      }
    ]);
    await sendMsg(jsonMsg(Msg.streamSettings, {'scale': p['scale'], 'fps': p['fps'], 'video': p['video']}));
    if (welcome['share'] == true && p['mount'] == true) {
      try {
        final dav = await link.startDav(welcome['name'] as String? ?? 'Remote');
        toMain.send(['mount', dav.url, dav.volumeName]);
      } catch (_) {}
    }
    // Keep-alive so idle sessions survive NAT timeouts and host read timeouts.
    final ping = Timer.periodic(const Duration(seconds: 10), (_) => sendMsg(Uint8List.fromList([Msg.ping])));
    try {
      while (true) {
        final m = await ch.open(await sock.next(timeout: const Duration(seconds: 45)));
        if (m.isEmpty || link.handle(m)) continue;
        switch (m[0]) {
          case Msg.frame:
            decoder.apply(m);
            await sendMsg(Uint8List.fromList([Msg.frameAck]));
            dirty = true;
            if (!waitingShown) post();
          case Msg.screenInfo:
            final j = jsonBody(m);
            toMain.send(['screen', j['w'], j['h']]);
          case Msg.clipboard:
            toMain.send(['clip', textBody(m)]);
          case Msg.bye:
            throw const SocketException('closed by peer');
        }
      }
    } finally {
      ping.cancel();
    }
  } on _Remote catch (e) {
    toMain.send(['error', e.code]);
  } on SocketException catch (e) {
    if (!closing) toMain.send(['error', ch == null ? 'Could not reach the device: ${e.osError?.message ?? e.message}' : 'Disconnected.']);
  } on TimeoutException {
    if (!closing) toMain.send(['error', 'The device did not respond.']);
  } on DecryptError {
    toMain.send(['error', 'Connection tampered with or corrupted; disconnected.']);
  } catch (e) {
    if (!closing) toMain.send(['error', '$e']);
  } finally {
    await link?.close();
    await sock?.close();
    toMain.send(['closed']);
    rx.close();
  }
}

class _Remote implements Exception {
  _Remote(this.code);
  final String code;
}
