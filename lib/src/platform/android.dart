// Android host/client glue: MediaProjection capture and AccessibilityService
// gestures live in Kotlin (MainActivity.kt / LocalviewAccessibilityService.kt).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../codec.dart';
import '../protocol.dart';
import 'keymap.dart';
import 'platform.dart';
import '../files.dart';

const MethodChannel androidChannel = MethodChannel('localview/android');

class AndroidBridge {
  /// ADB over Localview: developer options / wireless debugging state and this device's adb ports.
  static Future<Map<String, Object?>> adbStatus() async {
    final m = (await androidChannel.invokeMapMethod<String, Object?>('adbStatus')) ?? {};
    // Classic `adb tcpip`: check whether adbd really listens there.
    final legacy = m['legacy'] as int?;
    if (legacy != null) {
      try {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, legacy, timeout: const Duration(seconds: 1));
        s.destroy();
      } catch (_) {
        m['legacy'] = null;
      }
    }
    return m;
  }

  static Future<void> openDeveloperOptions() => androidChannel.invokeMethod('openDeveloperOptions');

  /// Shared-storage root listing every mounted volume (internal storage, SD cards, USB drives)
  /// as Android reports them; falls back to scanning /storage.
  static Future<String> storageRoot() async {
    try {
      final l = await androidChannel.invokeListMethod<Map>('storageVolumes') ?? const [];
      final out = <({String name, String path})>[];
      for (final v in l) {
        final path = v['path'] as String?;
        if (path == null) continue;
        final id = path.substring(path.lastIndexOf('/') + 1);
        final desc = (v['description'] as String?)?.replaceAll('/', ' ').trim();
        final name = v['primary'] == true
            ? FsServer.internalName
            : '${desc == null || desc.isEmpty ? (v['removable'] == true ? 'SD card' : 'Storage') : desc} ($id)';
        if (out.any((o) => o.name == name)) continue;
        out.add((name: name, path: path));
      }
      return androidVolumesRoot(out);
    } catch (_) {
      return kAndroidVolumesRoot;
    }
  }

  static Future<bool> startCapture() async => await androidChannel.invokeMethod<bool>('startCapture') ?? false;
  static Future<void> stopCapture() => androidChannel.invokeMethod('stopCapture');
  static Future<bool> isCapturing() async => await androidChannel.invokeMethod<bool>('isCapturing') ?? false;
  static Future<bool> accessibilityEnabled() async =>
      await androidChannel.invokeMethod<bool>('accessibilityEnabled') ?? false;
  static Future<void> openAccessibilitySettings() => androidChannel.invokeMethod('openAccessibilitySettings');
  static Future<bool> hasAllFilesAccess() async => await androidChannel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
  static Future<void> requestAllFilesAccess() => androidChannel.invokeMethod('requestAllFilesAccess');
  static Future<bool> isTv() async => await androidChannel.invokeMethod<bool>('isTv') ?? false;
  static Future<void> addDrive(String id, String name, String url) =>
      androidChannel.invokeMethod('addDrive', {'id': id, 'name': name, 'url': url});
  static Future<void> removeDrive(String id) => androidChannel.invokeMethod('removeDrive', {'id': id});

  static Future<RawFrame?> grab() async {
    final m = await androidChannel.invokeMapMethod<String, Object?>('grab');
    if (m == null) return null;
    final w = m['w'] as int, h = m['h'] as int;
    return RawFrame(w, h, w * 4, m['data'] as Uint8List, PixelFmt.rgba);
  }
}

/// Converts remote mouse/keyboard input into accessibility gestures.
class AndroidInjector implements InputInjector {
  double _x = 0.5, _y = 0.5;
  final List<double> _path = [];
  DateTime _downAt = DateTime(0);
  int? _down;

  void _call(String m, [Map<String, Object?>? a]) => androidChannel.invokeMethod(m, a).catchError((_) => null);

  @override
  void inject(InputEvent e, {MonitorInfo? monitor}) {
    switch (e) {
      case PointerMove(:final x, :final y):
        _x = x;
        _y = y;
        if (_down != null && _path.length < 400) _path.addAll([x, y]);
      case PointerButton(:final button, :final down):
        if (down) {
          _down = button;
          _downAt = DateTime.now();
          _path
            ..clear()
            ..addAll([_x, _y]);
          return;
        }
        if (_down == null) return;
        final ms = DateTime.now().difference(_downAt).inMilliseconds;
        final dx = _x - _path[0], dy = _y - _path[1];
        final moved = (dx * dx + dy * dy) > 0.0004;
        if (_down == Btn.right) {
          _call('global', {'action': Special.back});
        } else if (!moved) {
          _call(ms > 550 ? 'longPress' : 'tap', {'x': _x, 'y': _y});
        } else {
          final pts = <double>[];
          final n = _path.length ~/ 2;
          final step = n > 20 ? n / 20 : 1.0;
          for (double i = 0; i < n; i += step) {
            pts.addAll([_path[i.floor() * 2], _path[i.floor() * 2 + 1]]);
          }
          pts.addAll([_x, _y]);
          _call('swipe', {'points': Float64List.fromList(pts), 'ms': ms.clamp(50, 3000)});
        }
        _down = null;
      case Scroll(:final dx, :final dy):
        _call('scroll', {'x': _x, 'y': _y, 'dx': dx, 'dy': dy});
      case KeyInput(:final hid, :final down):
        if (!down) return;
        final u = hid & 0xFFFF;
        if (u == 0x29) _call('global', {'action': Special.back});
        if (u == 0x2A) _call('key', {'key': 'backspace'});
        if (u == 0x28 || u == 0x58) _call('key', {'key': 'enter'});
        if (isMeta(hid)) _call('global', {'action': Special.home});
      case TextEntry(:final text):
        _call('text', {'text': text});
      case PadState():
        break; // handled by GamepadInjector
      case SpecialAction(:final action):
        _call('global', {'action': action});
    }
  }
}
