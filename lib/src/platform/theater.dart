import 'dart:io';

import 'package:flutter/services.dart';

import 'android.dart';

/// Screen-size presets for the VR theater (width in meters, distance in meters).
const theaterSizes = <String, (String, double, double)>{
  'small': ('Small · 1.5 m', 1.5, 1.6),
  'medium': ('Medium · 3 m', 3.0, 2.5),
  'large': ('Large · 5 m', 5.0, 3.6),
  'cinema': ('Cinema · 10 m', 10.0, 7.0),
};

const theaterEnvironments = <String, String>{
  'void': 'Dark void',
  'passthrough': 'Passthrough (see your room)',
  'system': 'System environment',
};

/// Theater mode: fullscreen everywhere; on Android XR additionally a large
/// screen floating in Full Space (Virtual-Desktop style).
class Theater {
  static const _window = MethodChannel('localview/window');
  static bool? _xr;

  static Future<bool> xrAvailable() async {
    if (!Platform.isAndroid) return false;
    try {
      return _xr ??= await androidChannel.invokeMethod<bool>('xr.available') ?? false;
    } catch (_) {
      return _xr = false;
    }
  }

  static Future<void> enter({String size = 'medium', String environment = 'void', double aspect = 16 / 9}) async {
    await setFullscreen(true);
    if (await xrAvailable()) {
      final s = theaterSizes[size] ?? theaterSizes['medium']!;
      await androidChannel.invokeMethod('xr.enterTheater',
          {'width': s.$2, 'distance': s.$3, 'environment': environment, 'aspect': aspect});
    }
  }

  static Future<void> setEnvironment(String environment) async {
    if (await xrAvailable()) await androidChannel.invokeMethod('xr.setEnvironment', {'environment': environment});
  }

  static Future<void> exit() async {
    if (await xrAvailable()) await androidChannel.invokeMethod('xr.exitTheater');
    await setFullscreen(false);
  }

  static Future<void> setFullscreen(bool on) async {
    if (Platform.isAndroid || Platform.isIOS) {
      await SystemChrome.setEnabledSystemUIMode(on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
      return;
    }
    try {
      await _window.invokeMethod('setFullscreen', on);
    } catch (_) {}
  }
}
