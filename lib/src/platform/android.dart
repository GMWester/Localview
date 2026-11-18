// Android host/client glue: MediaProjection capture and AccessibilityService
// gestures live in Kotlin (MainActivity.kt / LocalviewAccessibilityService.kt).
import 'dart:async';
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
  /// Localview Pro: {pro: build has the helper, running, command: shell command that starts it}.
  static Future<Map<String, Object?>> proStatus() async =>
      (await androidChannel.invokeMapMethod<String, Object?>('pro.status')) ?? const {'pro': false};

  /// ADB over Localview: developer options / wireless debugging state and this device's adb ports.
  static Future<Map<String, Object?>> adbStatus() async {
    final m = (await androidChannel.invokeMapMethod<String, Object?>('adbStatus')) ?? {};
    try {
      final pro = await proStatus();
      if (pro['pro'] == true) {
        m['proCommand'] = pro['command'];
        m['proRunning'] = pro['running'] == true;
        m['proError'] = pro['error'];
        m['proLog'] = pro['log'];
      }
    } catch (_) {}
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

  /// Switches the screen to 'portrait', 'landscape' or 'auto'. Returns 'permission' when the
  /// user still has to allow "Modify system settings" (that screen is opened), other errors, or null.
  /// Display off (Localview Pro) or dimmed (fallback) while controlled; {mode, error?}.
  static Future<Map<String, Object?>> screenPower(bool on) async =>
      (await androidChannel.invokeMapMethod<String, Object?>('screenPower', {'on': on})) ?? const {'mode': 'on'};

  /// Phone sound for the controlling device (Android 10+): PCM s16le, stereo, 48 kHz.
  static Future<bool> audioSupported() async => await androidChannel.invokeMethod<bool>('audioSupported') ?? false;
  static Future<String?> audioStart({required bool silence}) =>
      androidChannel.invokeMethod<String>('audioStart', {'silence': silence});
  static Future<Uint8List?> audioRead() => androidChannel.invokeMethod<Uint8List>('audioRead');
  static Future<void> audioStop() => androidChannel.invokeMethod('audioStop');

  static Future<String?> setRotation(String mode) =>
      androidChannel.invokeMethod<String>('setRotation', {'mode': mode});

  /// The newest screen image as JPEG, or null if it is still [lastSeq] (nothing changed).
  static Future<JpegFrame?> grabJpeg(int lastSeq, {int maxSide = 1920, int quality = 70}) async {
    final m = await androidChannel
        .invokeMapMethod<String, Object?>('grabJpeg', {'last': lastSeq, 'maxSide': maxSide, 'quality': quality});
    if (m == null) return null;
    return JpegFrame(m['seq'] as int, m['w'] as int, m['h'] as int, m['jpeg'] as Uint8List);
  }

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

  bool _ctrl = false;

  /// Android 8+: the finger follows the pointer live (touchDown / touchMove / touchUp).
  bool? _live;
  bool _liveDown = false;
  Timer? _moveTimer;
  bool _movePending = false;

  // Wheel notches are combined for a moment into one swipe (each swipe cancels the previous).
  double _wheelX = 0, _wheelY = 0;
  Timer? _wheelTimer;

  void _call(String m, [Map<String, Object?>? a]) => androidChannel.invokeMethod(m, a).catchError((_) => null);

  AndroidInjector() {
    // Live touch needs Android 8+ and the accessibility service; checked again later if it was off.
    _checkLive();
    _checkPro();
  }

  // Localview Pro: real mouse & keyboard events through the shell helper, when it is running.
  bool _proBuild = false;
  bool _pro = false;
  Timer? _proTimer;
  bool _proMovePending = false;
  Timer? _proMoveTimer;

  void _checkPro() {
    AndroidBridge.proStatus().then((st) {
      _proBuild = st['pro'] == true;
      _pro = st['running'] == true;
      if (_proBuild) _proTimer ??= Timer.periodic(const Duration(seconds: 5), (_) => _checkPro());
    }).catchError((_) {});
  }

  void _pc(String m, Map<String, Object?> a) {
    androidChannel.invokeMethod<bool>(m, a).then((ok) {
      if (ok == false && m != 'pro.key') _pro = false; // helper gone: back to touch until it is started again
    }).catchError((_) {
      _pro = false;
    });
  }

  /// Real mouse & keyboard. Returns true if [e] was handled.
  bool _injectPro(InputEvent e) {
    switch (e) {
      case PointerMove(:final x, :final y):
        _x = x;
        _y = y;
        _proMovePending = true;
        _proMoveTimer ??= Timer(const Duration(milliseconds: 8), () {
          _proMoveTimer = null;
          if (_proMovePending) {
            _proMovePending = false;
            _pc('pro.move', {'x': _x, 'y': _y});
          }
        });
        return true;
      case PointerButton(:final button, :final down):
        _proMovePending = false;
        _pc('pro.button', {'button': button, 'down': down, 'x': _x, 'y': _y});
        return true;
      case Scroll(:final dx, :final dy):
        _pc('pro.scroll', {'x': _x, 'y': _y, 'dx': dx, 'dy': dy});
        return true;
      case KeyInput(:final hid, :final down):
        _pc('pro.key', {'hid': hid, 'down': down});
        return true;
      case TextEntry(:final text):
        androidChannel.invokeMethod<bool>('pro.text', {'text': text}).then((ok) {
          if (ok != true) _call('text', {'text': text}); // not on the virtual keyboard: accessibility
        }).catchError((_) => _call('text', {'text': text}));
        return true;
      default:
        return false;
    }
  }

  void _checkLive() {
    androidChannel.invokeMethod<bool>('liveTouch').then((ok) => _live = ok == true ? true : null).catchError((_) => null);
  }

  void _flushMove() {
    if (!_movePending || !_liveDown) return;
    _movePending = false;
    _call('touchMove', {'x': _x, 'y': _y});
  }

  @override
  void inject(InputEvent e, {MonitorInfo? monitor}) {
    if (_pro && !_liveDown && _injectPro(e)) return;
    switch (e) {
      case PointerMove(:final x, :final y):
        _x = x;
        _y = y;
        if (_liveDown) {
          // At most one move segment per ~16 ms, always to the newest position.
          _movePending = true;
          _moveTimer ??= Timer(const Duration(milliseconds: 16), () {
            _moveTimer = null;
            _flushMove();
          });
          return;
        }
        if (_down != null && _path.length < 400) _path.addAll([x, y]);
      case PointerButton(:final button, :final down):
        if (button == Btn.right) {
          if (down) _call('global', {'action': Special.back});
          return;
        }
        if (_live == null && down) _checkLive();
        if (_live == true) {
          if (down) {
            _down = button;
            _liveDown = true;
            _call('touchDown', {'x': _x, 'y': _y});
          } else if (_liveDown) {
            _moveTimer?.cancel();
            _moveTimer = null;
            _movePending = false;
            _liveDown = false;
            _down = null;
            _call('touchUp', {'x': _x, 'y': _y});
          }
          return;
        }
        if (down) {
          _down = button;
          _downAt = DateTime.now();
          _path
            ..clear()
            ..addAll([_x, _y]);
          return;
        }
        if (_down == null) return;
        // Android 7: replay the gesture on release.
        final ms = DateTime.now().difference(_downAt).inMilliseconds;
        final dx = _x - _path[0], dy = _y - _path[1];
        final moved = (dx * dx + dy * dy) > 0.0004;
        if (!moved) {
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
        _wheelX += dx;
        _wheelY += dy;
        _wheelTimer ??= Timer(const Duration(milliseconds: 40), () {
          _wheelTimer = null;
          final sx = _wheelX.clamp(-8.0, 8.0), sy = _wheelY.clamp(-8.0, 8.0);
          _wheelX = 0;
          _wheelY = 0;
          _call('scroll', {'x': _x, 'y': _y, 'dx': sx, 'dy': sy});
        });
      case KeyInput(:final hid, :final down):
        final u = hid & 0xFFFF;
        if (u == 0xE0 || u == 0xE4) _ctrl = down; // left / right Ctrl
        if (!down) return;
        if (_ctrl) {
          final k = switch (u) { 0x04 => 'selectAll', 0x06 => 'copy', 0x1B => 'cut', 0x19 => 'paste', _ => null };
          if (k != null) _call('key', {'key': k});
          return;
        }
        final k = switch (u) {
          0x2A => 'backspace',
          0x4C => 'delete',
          0x28 || 0x58 => 'enter',
          0x2B => 'tab',
          0x50 => 'left',
          0x4F => 'right',
          0x52 => 'up',
          0x51 => 'down',
          0x4A => 'home',
          0x4D => 'end',
          _ => null,
        };
        if (k != null) _call('key', {'key': k});
        if (u == 0x29) _call('global', {'action': Special.back}); // Esc
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
