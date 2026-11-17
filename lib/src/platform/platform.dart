import 'dart:io';

import '../codec.dart';
import '../protocol.dart';
import 'linux_x11.dart' as x11;
import 'macos.dart' as mac;
import 'windows.dart' as win;

/// One monitor of the host. Coordinates are in the platform's global desktop
/// space (physical pixels on Windows / X11, points on macOS).
class MonitorInfo {
  const MonitorInfo(this.id, this.name, this.x, this.y, this.w, this.h, {this.primary = false, this.osIndex});
  final String id;
  final String name;
  final int x, y, w, h;
  final bool primary;

  /// Position in the OS's own monitor order (used to pick the same screen for game mode).
  final int? osIndex;

  /// The whole desktop spanning every monitor.
  static const allId = 'all';
  bool get isAll => id == allId;

  Map<String, Object?> toJson() =>
      {'id': id, 'name': name, 'x': x, 'y': y, 'w': w, 'h': h, 'primary': primary, 'os': osIndex};
  factory MonitorInfo.fromJson(Map j) => MonitorInfo(j['id'] as String, j['name'] as String, j['x'] as int,
      j['y'] as int, j['w'] as int, j['h'] as int, primary: j['primary'] == true, osIndex: j['os'] as int?);

  @override
  bool operator ==(Object other) =>
      other is MonitorInfo && other.id == id && other.x == x && other.y == y && other.w == w && other.h == h && other.name == name;
  @override
  int get hashCode => Object.hash(id, x, y, w, h);
}

/// Monitors of this computer: primary first, then left to right; "All displays" last when
/// there are several and the platform can capture the whole desktop. Empty when unknown.
List<MonitorInfo> listMonitors() {
  List<MonitorInfo> l = const [];
  try {
    if (Platform.isWindows) l = win.winMonitors();
    if (Platform.isLinux) l = x11.x11Monitors();
    if (Platform.isMacOS) l = mac.macMonitors();
  } catch (e) {
    stderr.writeln('Localview: cannot list monitors: $e');
  }
  final single = l.where((m) => !m.isAll).toList()
    ..sort((a, b) => a.primary != b.primary ? (a.primary ? -1 : 1) : (a.x != b.x ? a.x - b.x : a.y - b.y));
  final all = l.where((m) => m.isAll);
  return [...single, if (single.length > 1) ...all];
}

/// Finds [id] in [list]; falls back to the primary (first) monitor.
MonitorInfo? pickMonitor(List<MonitorInfo> list, String? id) {
  if (list.isEmpty) return null;
  for (final m in list) {
    if (m.id == id) return m;
  }
  return list.first;
}

abstract class ScreenCapturer {
  /// Captures [monitor] (null: the primary monitor).
  RawFrame? capture({MonitorInfo? monitor});
  void dispose();
}

abstract class InputInjector {
  /// Injects [e]; pointer positions (0..1) are relative to [monitor] (null: the primary monitor).
  void inject(InputEvent e, {MonitorInfo? monitor});
}

/// Desktop screen capture via FFI. Safe to call inside a background isolate.
/// Returns null on platforms that capture on the main isolate (Android) or cannot host.
ScreenCapturer? createScreenCapturer() {
  try {
    if (Platform.isWindows) return win.WinCapturer();
    if (Platform.isLinux) return x11.X11Capturer();
    if (Platform.isMacOS) return mac.MacCapturer();
  } catch (e) {
    stderr.writeln('Localview: screen capture unavailable: $e');
  }
  return null;
}

/// Desktop input injection via FFI (main isolate).
InputInjector? createDesktopInjector() {
  try {
    if (Platform.isWindows) return win.WinInjector();
    if (Platform.isLinux) return x11.X11Injector();
    if (Platform.isMacOS) return mac.MacInjector();
  } catch (e) {
    stderr.writeln('Localview: input injection unavailable: $e');
  }
  return null;
}

/// Draws a small arrow pointer into a 32-bit frame (for capture APIs that omit the cursor).
void drawArrow(RawFrame f, int cx, int cy) {
  const shape = [
    'X           ',
    'XX          ',
    'X.X         ',
    'X..X        ',
    'X...X       ',
    'X....X      ',
    'X.....X     ',
    'X......X    ',
    'X.......X   ',
    'X........X  ',
    'X.....XXXXX ',
    'X..X..X     ',
    'X.X X..X    ',
    'XX  X..X    ',
    'X    X..X   ',
    '     X..X   ',
    '      XX    ',
  ];
  final scale = (f.width > 2500 || f.height > 1800) ? 2 : 1;
  final px = f.pixels;
  for (var sy = 0; sy < shape.length * scale; sy++) {
    final y = cy + sy;
    if (y < 0 || y >= f.height) continue;
    final row = shape[sy ~/ scale];
    for (var sx = 0; sx < row.length * scale; sx++) {
      final x = cx + sx;
      if (x < 0 || x >= f.width) continue;
      final c = row[sx ~/ scale];
      if (c == ' ') continue;
      final v = c == 'X' ? 0 : 255;
      final o = y * f.stride + x * 4;
      px[o] = v;
      px[o + 1] = v;
      px[o + 2] = v;
      px[o + 3] = 255;
    }
  }
}
