import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'config.dart';
import 'discovery.dart';
import 'host.dart';
import 'platform/android.dart';
import 'platform/drives.dart';
import 'platform/platform.dart';
import 'storage.dart';
import 'upnp.dart';

/// Owns long-lived services: hosting, discovery responder, UPnP, drive mounts.
class AppController extends ChangeNotifier {
  AppController(this.store);

  final AppStore store;
  late final HostService host;
  DiscoveryResponder? _responder;
  final Upnp upnp = Upnp();
  final DriveMounter drives = DriveMounter();
  final Map<String, String> mountedDrives = {}; // key -> location text
  bool isTv = false;
  bool upnpBusy = false;
  List<String> localIps = [];
  String? hostWarning;

  Future<void> init() async {
    if (Platform.isAndroid) {
      try {
        isTv = await AndroidBridge.isTv();
      } catch (_) {}
    }
    host = HostService(
      store,
      externalCapture: Platform.isAndroid ? AndroidBridge.grab : null,
      injector: Platform.isAndroid ? AndroidInjector() : createDesktopInjector(),
    )
      ..onClipboardSet = ((t) {
        Clipboard.setData(ClipboardData(text: t));
      })
      ..onClipboardGet = (() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text)
      ..onMount = ((sid, name, url, volume) async {
        await mountDrive('host-$sid', name, url, volume);
      })
      ..onUnmount = ((sid) => unmountDrive('host-$sid'));
    host.addListener(notifyListeners);
    if (Platform.isLinux && (Platform.environment['XDG_SESSION_TYPE'] ?? '') == 'wayland') {
      hostWarning = 'Wayland session detected: screen capture only works in an X11 (Xorg) session.';
    }
    localIps = await localAddresses();
    if (kCanHost && store.hostEnabled) await startHosting();
    _responder = DiscoveryResponder(() => store.hostEnabled && host.running
        ? {'id': store.deviceId, 'name': store.deviceName, 'os': kOsName, 'port': host.boundPort ?? store.tcpPort, 'pw': store.hasPassword}
        : null);
    if (kIsLan) await _responder!.start();
    notifyListeners();
  }

  Future<void> startHosting() async {
    await host.start();
    if (kIsWan && store.upnpEnabled) unawaited(refreshUpnp());
    notifyListeners();
  }

  Future<void> stopHosting() async {
    await host.stop();
    if (kIsWan) await upnp.unmapPort(store.tcpPort);
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

  Future<void> unmountDrive(String key) async {
    await drives.unmount(key);
    mountedDrives.remove(key);
    notifyListeners();
  }

  Future<void> shutdown() async {
    await drives.unmountAll();
    _responder?.stop();
    await host.stop();
  }
}
