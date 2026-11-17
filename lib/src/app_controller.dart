import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'config.dart';
import 'discovery.dart';
import 'host.dart';
import 'platform/android.dart';
import 'platform/drives.dart';
import 'platform/gamepad_host.dart';
import 'protocol.dart';
import 'platform/platform.dart';
import 'stream/pcvr.dart';
import 'stream/rtc.dart';
import 'storage.dart';
import 'upnp.dart';
import 'background.dart';
import 'client.dart';
import 'platform/speakers.dart';

/// Owns long-lived services: hosting, discovery responder, UPnP, drive mounts.
class AppController extends ChangeNotifier {
  AppController(this.store);

  final AppStore store;
  late final HostService host;
  DiscoveryResponder? _responder;

  /// LAN discovery (LAN and combined builds).
  DiscoveryScanner? scanner;
  final Upnp upnp = Upnp();
  final DriveMounter drives = DriveMounter();
  final Map<String, String> mountedDrives = {}; // key -> location text
  bool isTv = false;

  /// Open connections to other devices (they stay open while the window is closed).
  final Set<ClientSession> clients = {};
  late final BackgroundKeeper background = BackgroundKeeper(this);

  void trackClient(ClientSession s) {
    if (s.closed || !clients.add(s)) return;
    void onChange() {
      if (s.closed) {
        s.removeListener(onChange);
        clients.remove(s);
        notifyListeners();
      }
    }

    s.addListener(onChange);
    notifyListeners();
  }

  /// Virtual controllers for game streaming (desktop hosts).
  VirtualPads? pads;
  final Map<int, RtcHostSession> _rtc = {};
  bool upnpBusy = false;
  List<String> localIps = [];
  String? hostWarning;

  /// Viewer windows: no hosting, discovery or drives - just what the remote view needs.
  Future<void> initViewer() async {
    if (Platform.isAndroid) {
      try {
        isTv = await AndroidBridge.isTv();
      } catch (_) {}
    }
  }

  // Sound only on the controlling device: viewers (session ids) that asked for it.
  final Speakers? _speakers = createSpeakers();
  final Set<int> _soundHere = {};
  bool _silenced = false;

  Future<String?> _applySpeakers() async {
    final want = _soundHere.isNotEmpty;
    if (want == _silenced || _speakers == null) return null;
    final err = await _speakers.silence(want);
    if (err == null) {
      _silenced = want;
      // Linux: the sound now plays into another output; re-capture it for running streams.
      for (final r in _rtc.values) {
        unawaited(r.reloadAudio().catchError((_) {}));
      }
    }
    return err;
  }

  Future<void> _routeAudio(int sid, String mode) async {
    if (mode == 'viewer') {
      _soundHere.add(sid);
    } else {
      _soundHere.remove(sid);
    }
    final err = _speakers == null ? 'This device cannot silence its speakers' : await _applySpeakers();
    host.sendRtc(sid, jsonMsg(Msg.audioRouteResult, {'mode': mode, 'error': ?err}));
  }

  Future<void> init() async {
    if (Platform.isAndroid) {
      try {
        isTv = await AndroidBridge.isTv();
      } catch (_) {}
    }
    pads = Platform.isAndroid || Platform.isIOS ? null : createVirtualPads();
    host = HostService(
      store,
      externalCapture: Platform.isAndroid ? AndroidBridge.grab : null,
      externalJpeg: Platform.isAndroid
          ? (last, maxSide, quality) => AndroidBridge.grabJpeg(last, maxSide: maxSide, quality: quality)
          : null,
      injector: Platform.isAndroid ? AndroidInjector() : GamepadInjector(createDesktopInjector(), pads!),
    )
      ..onClipboardSet = ((t) {
        Clipboard.setData(ClipboardData(text: t));
      })
      ..onClipboardGet = (() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text)
      ..onMount = ((sid, name, url, volume) async {
        await mountDrive('host-$sid', name, url, volume);
      })
      ..onUnmount = ((sid) => unmountDrive('host-$sid'))
      ..onAdbInfo = (Platform.isAndroid ? AndroidBridge.adbStatus : null)
      ..onRotate = (Platform.isAndroid ? AndroidBridge.setRotation : null);
    host
      ..rtcCapable = rtcHostSupported && await rtcUsable()
      ..audioRouteCapable = _speakers != null
      ..padsCapable = pads != null
      ..vrCapable = pcvrHostSupported
      ..onRtc = ((sid, m) {
        if (m[0] == Msg.audioRoute) {
          unawaited(_routeAudio(sid, jsonBody(m)['mode'] as String? ?? 'host'));
          return;
        }
        if (Msg.isVr(m[0])) {
          unawaited(PcvrHost(send: (x) => host.sendRtc(sid, x), upnp: kHasWan ? upnp : null).handle(m));
          return;
        }
        final r = _rtc.putIfAbsent(sid, () => RtcHostSession((x) => host.sendRtc(sid, x)));
        unawaited(r.handle(m));
      })
      ..onSessionEnded = ((sid) {
        unawaited(_rtc.remove(sid)?.stop());
        if (_soundHere.remove(sid)) unawaited(_applySpeakers());
      });
    host.addListener(notifyListeners);
    if (Platform.isLinux && (Platform.environment['XDG_SESSION_TYPE'] ?? '') == 'wayland') {
      hostWarning = 'Wayland session detected: screen capture only works in an X11 (Xorg) session.';
    }
    localIps = await localAddresses();
    if (kCanHost && store.hostEnabled) await startHosting();
    await background.start();
    if (Platform.isAndroid) {
      // SD cards and USB drives come and go: keep the shared volumes current.
      Timer.periodic(const Duration(seconds: 10), (_) async => store.setFsRoot(await AndroidBridge.storageRoot()));
    }
    _responder = DiscoveryResponder(() => store.hostEnabled && host.running
        ? {
            'id': store.deviceId,
            'name': store.deviceName,
            'os': kOsName,
            'port': host.boundPort ?? store.tcpPort,
            'pw': store.hasPassword,
            'totp': store.totpEnabled,
          }
        : null);
    if (kHasLan) {
      await _responder!.start();
      scanner = DiscoveryScanner(store.deviceId);
      await scanner!.start();
    }
    notifyListeners();
  }

  Future<void> startHosting() async {
    await host.start();
    if (kHasWan && store.upnpEnabled) unawaited(refreshUpnp());
    notifyListeners();
  }

  Future<void> stopHosting() async {
    await host.stop();
    if (kHasWan) await upnp.unmapPort(store.tcpPort);
    notifyListeners();
  }

  Future<void> setHostEnabled(bool v) async {
    store.hostEnabled = v;
    await store.save();
    if (v) {
      await startHosting();
    } else {
      await stopHosting();
    }
  }

  Future<void> refreshUpnp() async {
    upnpBusy = true;
    notifyListeners();
    await upnp.mapPort(store.tcpPort);
    localIps = await localAddresses();
    upnpBusy = false;
    host.publicIp = upnp.externalIp;
    notifyListeners();
  }

  Future<String?> mountDrive(String key, String name, String url, String volume) async {
    if (!store.mountDrives) return null;
    final where = await drives.mount(key, name, url, volume);
    if (where != null) {
      mountedDrives[key] = '$name — $where';
      notifyListeners();
    }
    return where;
  }

  /// Quits completely: disconnects, unmounts drives, stops hosting and the background service.
  Future<void> quit() async {
    if (_silenced) await _speakers?.silence(false);
    for (final c in clients.toList()) {
      try {
        await c.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    for (final k in mountedDrives.keys.toList()) {
      try {
        await unmountDrive(k).timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    try {
      await host.stop().timeout(const Duration(seconds: 2));
    } catch (_) {}
    if (Platform.isAndroid) {
      try {
        await androidChannel.invokeMethod('setKeepAlive', {'on': false, 'tip': ''});
        await AndroidBridge.stopCapture();
      } catch (_) {}
    }
    exit(0);
  }

  Future<void> unmountDrive(String key) async {
    await drives.unmount(key);
    mountedDrives.remove(key);
    notifyListeners();
  }

  Future<void> shutdown() async {
    await drives.unmountAll();
    _responder?.stop();
    scanner?.dispose();
    for (final r in _rtc.values) {
      await r.stop();
    }
    pads?.dispose();
    await host.stop();
  }
}
