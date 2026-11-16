import 'dart:io';

import '../codec.dart';
import '../protocol.dart';
import 'linux_x11.dart' as x11;
import 'macos.dart' as mac;
import 'windows.dart' as win;

abstract class ScreenCapturer {
  RawFrame? capture();
  void dispose();
}

abstract class InputInjector {
  void inject(InputEvent e);
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
  final scale = f.width > 2500 ? 2 : 1;
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
