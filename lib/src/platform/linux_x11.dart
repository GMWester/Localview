// Linux (X11): XGetImage capture with XFixes cursor, XTest input injection.
// Wayland sessions are not supported for hosting (log in with an X11/Xorg session).
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../codec.dart';
import '../protocol.dart';
import 'keymap.dart';
import 'platform.dart';

final DynamicLibrary _x11 = DynamicLibrary.open('libX11.so.6');

final _xOpenDisplay = _x11.lookupFunction<Pointer<Void> Function(Pointer<Utf8>), Pointer<Void> Function(Pointer<Utf8>)>('XOpenDisplay');
final _xCloseDisplay = _x11.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('XCloseDisplay');
final _xDefaultScreen = _x11.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('XDefaultScreen');
final _xRootWindow = _x11.lookupFunction<Uint64 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('XRootWindow');
final _xDisplayWidth = _x11.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('XDisplayWidth');
final _xDisplayHeight = _x11.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('XDisplayHeight');
final _xGetImage = _x11.lookupFunction<
    Pointer<Uint8> Function(Pointer<Void>, Uint64, Int32, Int32, Uint32, Uint32, Uint64, Int32),
    Pointer<Uint8> Function(Pointer<Void>, int, int, int, int, int, int, int)>('XGetImage');
final _xDestroyImage = _x11.lookupFunction<Int32 Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>('XDestroyImage');
final _xFree = _x11.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('XFree');
final _xFlush = _x11.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('XFlush');
final _xKeysymToKeycode =
    _x11.lookupFunction<Uint8 Function(Pointer<Void>, Uint64), int Function(Pointer<Void>, int)>('XKeysymToKeycode');
final _xKeycodeToKeysym = _x11
    .lookupFunction<Uint64 Function(Pointer<Void>, Uint8, Int32), int Function(Pointer<Void>, int, int)>('XKeycodeToKeysym');

final _xGetAtomName =
    _x11.lookupFunction<Pointer<Utf8> Function(Pointer<Void>, Uint64), Pointer<Utf8> Function(Pointer<Void>, int)>('XGetAtomName');

/// Monitors from XRandR (XRRGetMonitors), plus the whole root window as "All displays".
List<MonitorInfo> x11Monitors() {
  final d = _xOpenDisplay(nullptr);
  if (d == nullptr) return const [];
  try {
    final screen = _xDefaultScreen(d);
    final root = _xRootWindow(d, screen);
    final out = <MonitorInfo>[];
    try {
      final rr = DynamicLibrary.open('libXrandr.so.2');
      final getMonitors = rr.lookupFunction<Pointer<Uint8> Function(Pointer<Void>, Uint64, Int32, Pointer<Int32>),
          Pointer<Uint8> Function(Pointer<Void>, int, int, Pointer<Int32>)>('XRRGetMonitors');
      final freeMonitors = rr.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('XRRFreeMonitors');
      final n = calloc<Int32>();
      final mons = getMonitors(d, root, 1, n);
      try {
        // XRRMonitorInfo: Atom name; Bool primary, automatic; int noutput, x, y, width, height, mwidth, mheight; RROutput *outputs
        const size = 56;
        for (var i = 0; i < n.value && mons != nullptr; i++) {
          final b = ByteData.sublistView((mons + i * size).asTypedList(size));
          final atom = b.getUint64(0, Endian.host);
          var name = 'Display ${i + 1}';
          final pName = atom == 0 ? nullptr : _xGetAtomName(d, atom);
          if (pName != nullptr) {
            name = pName.toDartString();
            _xFree(pName.cast());
          }
          out.add(MonitorInfo(name, name, b.getInt32(20, Endian.host), b.getInt32(24, Endian.host),
              b.getInt32(28, Endian.host), b.getInt32(32, Endian.host),
              primary: b.getInt32(8, Endian.host) != 0, osIndex: i));
        }
      } finally {
        if (mons != nullptr) freeMonitors(mons);
        calloc.free(n);
      }
    } catch (_) {
      // No XRandR: the whole screen is the only monitor.
    }
    final w = _xDisplayWidth(d, screen), h = _xDisplayHeight(d, screen);
    if (out.isEmpty) return [MonitorInfo('screen', 'Screen', 0, 0, w, h, primary: true, osIndex: 0)];
    if (!out.any((m) => m.primary)) out[0] = MonitorInfo(out[0].id, out[0].name, out[0].x, out[0].y, out[0].w, out[0].h, primary: true, osIndex: out[0].osIndex);
    out.add(MonitorInfo(MonitorInfo.allId, 'All displays', 0, 0, w, h));
    return out;
  } finally {
    _xCloseDisplay(d);
  }
}

class X11Capturer implements ScreenCapturer {
  X11Capturer() {
    _d = _xOpenDisplay(nullptr);
    if (_d == nullptr) throw StateError('cannot open X display (Wayland-only session?)');
    _screen = _xDefaultScreen(_d);
    _root = _xRootWindow(_d, _screen);
    try {
      final xf = DynamicLibrary.open('libXfixes.so.3');
      _getCursor = xf.lookupFunction<Pointer<Uint8> Function(Pointer<Void>), Pointer<Uint8> Function(Pointer<Void>)>(
          'XFixesGetCursorImage');
    } catch (_) {}
  }

  late final Pointer<Void> _d;
  late final int _screen, _root;
  Pointer<Uint8> Function(Pointer<Void>)? _getCursor;
  Uint8List? _buf;

  @override
  RawFrame? capture({MonitorInfo? monitor}) {
    final rw = _xDisplayWidth(_d, _screen), rh = _xDisplayHeight(_d, _screen);
    // Clip to the root window (a monitor list can be briefly stale after a layout change).
    final ox = (monitor?.x ?? 0).clamp(0, rw - 1), oy = (monitor?.y ?? 0).clamp(0, rh - 1);
    final w = (monitor?.w ?? rw).clamp(1, rw - ox), h = (monitor?.h ?? rh).clamp(1, rh - oy);
    final img = _xGetImage(_d, _root, ox, oy, w, h, 0xFFFFFFFFFFFFFFFF, 2 /* ZPixmap */);
    if (img == nullptr) return null;
    try {
      final hdr = ByteData.sublistView(img.asTypedList(64));
      final data = Pointer<Uint8>.fromAddress(hdr.getUint64(16, Endian.host));
      final bpl = hdr.getInt32(44, Endian.host);
      final bpp = hdr.getInt32(48, Endian.host);
      if (bpp != 32) return null;
      final size = bpl * h;
      if (_buf == null || _buf!.length != size) _buf = Uint8List(size);
      _buf!.setAll(0, data.asTypedList(size));
      final f = RawFrame(w, h, bpl, _buf!, PixelFmt.bgra);
      _drawCursor(f, ox, oy);
      return f;
    } finally {
      _xDestroyImage(img);
    }
  }

  void _drawCursor(RawFrame f, int ox, int oy) {
    final g = _getCursor;
    if (g == null) return;
    final ci = g(_d);
    if (ci == nullptr) return;
    try {
      final b = ByteData.sublistView(ci.asTypedList(32));
      final cx = b.getInt16(0, Endian.host) - ox, cy = b.getInt16(2, Endian.host) - oy;
      final cw = b.getUint16(4, Endian.host), ch = b.getUint16(6, Endian.host);
      final hx = b.getUint16(8, Endian.host), hy = b.getUint16(10, Endian.host);
      final pix = Pointer<Uint64>.fromAddress(b.getUint64(24, Endian.host)).asTypedList(cw * ch);
      final px = f.pixels;
      for (var y = 0; y < ch; y++) {
        final sy = cy - hy + y;
        if (sy < 0 || sy >= f.height) continue;
        for (var x = 0; x < cw; x++) {
          final sx = cx - hx + x;
          if (sx < 0 || sx >= f.width) continue;
          final argb = pix[y * cw + x] & 0xFFFFFFFF;
          final a = argb >> 24;
          if (a == 0) continue;
          final o = sy * f.stride + sx * 4;
          final inv = 255 - a;
          px[o] = ((argb & 0xFF) + px[o] * inv ~/ 255).clamp(0, 255);
          px[o + 1] = (((argb >> 8) & 0xFF) + px[o + 1] * inv ~/ 255).clamp(0, 255);
          px[o + 2] = (((argb >> 16) & 0xFF) + px[o + 2] * inv ~/ 255).clamp(0, 255);
        }
      }
    } finally {
      _xFree(ci.cast());
    }
  }

  @override
  void dispose() => _xCloseDisplay(_d);
}

class X11Injector implements InputInjector {
  X11Injector() {
    _d = _xOpenDisplay(nullptr);
    if (_d == nullptr) throw StateError('cannot open X display');
    _screen = _xDefaultScreen(_d);
    final t = DynamicLibrary.open('libXtst.so.6');
    _motion = t.lookupFunction<Int32 Function(Pointer<Void>, Int32, Int32, Int32, Uint64),
        int Function(Pointer<Void>, int, int, int, int)>('XTestFakeMotionEvent');
    _button = t.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Int32, Uint64),
        int Function(Pointer<Void>, int, int, int)>('XTestFakeButtonEvent');
    _keyEv = t.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Int32, Uint64),
        int Function(Pointer<Void>, int, int, int)>('XTestFakeKeyEvent');
  }

  late final Pointer<Void> _d;
  late final int _screen;
  late final int Function(Pointer<Void>, int, int, int, int) _motion;
  late final int Function(Pointer<Void>, int, int, int) _button;
  late final int Function(Pointer<Void>, int, int, int) _keyEv;
  double _accX = 0, _accY = 0;

  void _click(int b) {
    _button(_d, b, 1, 0);
    _button(_d, b, 0, 0);
  }

  void _typeKeysym(int ks) {
    final kc = _xKeysymToKeycode(_d, ks);
    if (kc == 0) return;
    final needShift = _xKeycodeToKeysym(_d, kc, 0) != ks && _xKeycodeToKeysym(_d, kc, 1) == ks;
    final shift = _xKeysymToKeycode(_d, 0xffe1);
    if (needShift) _keyEv(_d, shift, 1, 0);
    _keyEv(_d, kc, 1, 0);
    _keyEv(_d, kc, 0, 0);
    if (needShift) _keyEv(_d, shift, 0, 0);
  }

  @override
  void inject(InputEvent e, {MonitorInfo? monitor}) {
    switch (e) {
      case PointerMove(:final x, :final y):
        final w = monitor?.w ?? _xDisplayWidth(_d, _screen), h = monitor?.h ?? _xDisplayHeight(_d, _screen);
        final ox = monitor?.x ?? 0, oy = monitor?.y ?? 0;
        _motion(_d, _screen, ox + (x.clamp(0.0, 1.0) * (w - 1)).round(), oy + (y.clamp(0.0, 1.0) * (h - 1)).round(), 0);
      case PointerButton(:final button, :final down):
        _button(_d, switch (button) { Btn.right => 3, Btn.middle => 2, _ => 1 }, down ? 1 : 0, 0);
      case Scroll(:final dx, :final dy):
        _accY += dy;
        _accX += dx;
        while (_accY >= 1) { _click(5); _accY -= 1; }
        while (_accY <= -1) { _click(4); _accY += 1; }
        while (_accX >= 1) { _click(7); _accX -= 1; }
        while (_accX <= -1) { _click(6); _accX += 1; }
      case KeyInput(:final hid, :final down):
        final ev = evdevFor(hid);
        if (ev != null) _keyEv(_d, ev + 8, down ? 1 : 0, 0);
      case TextEntry(:final text):
        for (final r in text.runes) {
          final ks = r == 10 || r == 13
              ? 0xff0d
              : r == 9
                  ? 0xff09
                  : r < 0x100
                      ? r
                      : 0x01000000 | r;
          _typeKeysym(ks);
        }
      case PadState():
        break; // handled by GamepadInjector
      case SpecialAction():
        break;
    }
    _xFlush(_d);
  }
}
