// Keep running in the background: while Localview is connected to other devices (or, on
// computers, can be controlled remotely), closing its window only hides it. Connections and
// the drives they share keep working; the window comes back from the tray icon (Windows,
// Linux), the Dock (macOS), the notification (Android) or by starting Localview again.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import 'app_controller.dart';
import 'config.dart';
import 'platform/android.dart';

const MethodChannel _window = MethodChannel('localview/window');

/// Loopback port where the running main window listens for "show" (one per variant).
int get _showPort => kDefaultTcpPort + (kModeName == 'combined' ? 22 : 12);

/// Desktop: if Localview is already running (perhaps hidden in the background), asks it to
/// show its window and returns true; this process should then exit.
Future<bool> showRunningInstance() async {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return false;
  try {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, _showPort, timeout: const Duration(milliseconds: 400));
    s.write('localview-show\n');
    await s.flush();
    final reply = await utf8.decoder.bind(s).first.timeout(const Duration(seconds: 1), onTimeout: () => '');
    await s.close();
    return reply.startsWith('ok');
  } catch (_) {
    return false;
  }
}

class BackgroundKeeper {
  BackgroundKeeper(this.app);
  final AppController app;

  /// True while the window is hidden in the background (video streams pause then).
  final ValueNotifier<bool> hidden = ValueNotifier(false);
  bool? _sentOn;
  String? _sentTip;
  ServerSocket? _server;
  AppLifecycleListener? _exitListener;
  AppLifecycleListener? get exitListener => _exitListener;

  Future<void> start() async {
    // The desktop embedders turn "close window" into an exit request; while there is
    // something to keep alive, hide the window instead of quitting.
    _exitListener = AppLifecycleListener(onExitRequested: () async {
      if (_sentOn != true) return AppExitResponse.exit;
      await hide();
      return AppExitResponse.cancel;
    });
    _window.setMethodCallHandler((call) async {
      if (call.method == 'hidden') hidden.value = call.arguments == true;
      return null;
    });
    app.addListener(_update);
    app.store.addListener(_update);
    _update();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      try {
        _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, _showPort);
        _server!.listen((c) {
          utf8.decoder.bind(c).first.then((line) async {
            if (line.startsWith('localview-show')) {
              c.write('ok\n');
              await show();
            }
            await c.close();
          }).catchError((_) {});
        });
      } catch (_) {
        // Port taken: starting Localview again just opens a second window.
      }
    }
  }

  Future<void> hide() async {
    try {
      await _window.invokeMethod('hide');
      hidden.value = true;
    } catch (_) {}
  }

  Future<void> show() async {
    try {
      await _window.invokeMethod('show');
    } catch (_) {}
    hidden.value = false;
  }

  void _update() {
    final n = app.clients.length;
    final reachable = kCanHost && app.store.hostEnabled && !Platform.isAndroid;
    final on = app.store.keepInBackground && (n > 0 || reachable);
    final tip = n > 0
        ? 'Localview: connected to $n device${n == 1 ? '' : 's'}'
        : 'Localview: can be controlled remotely';
    if (on == _sentOn && tip == _sentTip) return;
    _sentOn = on;
    _sentTip = tip;
    final args = {'on': on, 'tip': tip};
    if (Platform.isAndroid) {
      unawaited(androidChannel.invokeMethod('setKeepAlive', args).catchError((_) => null));
    } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      unawaited(_window.invokeMethod('setKeepAlive', args).catchError((_) => null));
    }
  }
}
