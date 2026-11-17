// macOS: CoreGraphics capture and CGEvent injection via dart:ffi.
// Requires "Screen Recording" and "Accessibility" permission for Localview.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../codec.dart';
import '../protocol.dart';
import 'keymap.dart';
import 'platform.dart';

final class CGPoint extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

final class CGRect extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
  @Double()
  external double w;
  @Double()
  external double h;
}

final DynamicLibrary _cg = DynamicLibrary.open('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
final DynamicLibrary _cf = DynamicLibrary.open('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');

final _mainDisplay = _cg.lookupFunction<Uint32 Function(), int Function()>('CGMainDisplayID');
final _displayBounds = _cg.lookupFunction<CGRect Function(Uint32), CGRect Function(int)>('CGDisplayBounds');
final _createImage = _cg.lookupFunction<Pointer<Void> Function(Uint32), Pointer<Void> Function(int)>('CGDisplayCreateImage');
final _imgW = _cg.lookupFunction<Size Function(Pointer<Void>), int Function(Pointer<Void>)>('CGImageGetWidth');
final _imgH = _cg.lookupFunction<Size Function(Pointer<Void>), int Function(Pointer<Void>)>('CGImageGetHeight');
final _imgBpr = _cg.lookupFunction<Size Function(Pointer<Void>), int Function(Pointer<Void>)>('CGImageGetBytesPerRow');
final _imgBpp = _cg.lookupFunction<Size Function(Pointer<Void>), int Function(Pointer<Void>)>('CGImageGetBitsPerPixel');
final _imgProvider =
    _cg.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('CGImageGetDataProvider');
final _providerCopy =
    _cg.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('CGDataProviderCopyData');
final _dataPtr = _cf.lookupFunction<Pointer<Uint8> Function(Pointer<Void>), Pointer<Uint8> Function(Pointer<Void>)>('CFDataGetBytePtr');
final _dataLen = _cf.lookupFunction<IntPtr Function(Pointer<Void>), int Function(Pointer<Void>)>('CFDataGetLength');
final _cfRelease = _cf.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CFRelease');
final _eventCreate = _cg.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('CGEventCreate');
final _eventLocation = _cg.lookupFunction<CGPoint Function(Pointer<Void>), CGPoint Function(Pointer<Void>)>('CGEventGetLocation');
final _mouseEvent = _cg.lookupFunction<Pointer<Void> Function(Pointer<Void>, Uint32, CGPoint, Uint32),
    Pointer<Void> Function(Pointer<Void>, int, CGPoint, int)>('CGEventCreateMouseEvent');
final _keyEvent = _cg.lookupFunction<Pointer<Void> Function(Pointer<Void>, Uint16, Bool),
    Pointer<Void> Function(Pointer<Void>, int, bool)>('CGEventCreateKeyboardEvent');
final _scrollEvent = _cg.lookupFunction<Pointer<Void> Function(Pointer<Void>, Uint32, Uint32, Int32, Int32, Int32),
    Pointer<Void> Function(Pointer<Void>, int, int, int, int, int)>('CGEventCreateScrollWheelEvent2');
final _post = _cg.lookupFunction<Void Function(Uint32, Pointer<Void>), void Function(int, Pointer<Void>)>('CGEventPost');
final _setInt = _cg.lookupFunction<Void Function(Pointer<Void>, Uint32, Int64), void Function(Pointer<Void>, int, int)>(
    'CGEventSetIntegerValueField');
final _setFlags = _cg.lookupFunction<Void Function(Pointer<Void>, Uint64), void Function(Pointer<Void>, int)>('CGEventSetFlags');
final _setUnicode = _cg.lookupFunction<Void Function(Pointer<Void>, UnsignedLong, Pointer<Uint16>),
    void Function(Pointer<Void>, int, Pointer<Uint16>)>('CGEventKeyboardSetUnicodeString');

final _activeDisplays = _cg.lookupFunction<Int32 Function(Uint32, Pointer<Uint32>, Pointer<Uint32>),
    int Function(int, Pointer<Uint32>, Pointer<Uint32>)>('CGGetActiveDisplayList');

/// Active displays (bounds in points, the coordinate space of CGEvent).
List<MonitorInfo> macMonitors() {
  final ids = calloc<Uint32>(16), n = calloc<Uint32>();
  try {
    if (_activeDisplays(16, ids, n) != 0) return const [];
    final main = _mainDisplay();
    return [
      for (var i = 0; i < n.value; i++)
        () {
          final id = ids[i];
          final b = _displayBounds(id);
          return MonitorInfo('$id', 'Display ${i + 1}', b.x.round(), b.y.round(), b.w.round(), b.h.round(),
              primary: id == main, osIndex: i);
        }(),
    ];
  } finally {
    calloc.free(ids);
    calloc.free(n);
  }
}

/// Permission helpers (macOS 10.15+).
bool macHasScreenAccess() {
  try {
    return _cg.lookupFunction<Bool Function(), bool Function()>('CGPreflightScreenCaptureAccess')();
  } catch (_) {
    return true;
  }
}

void macRequestScreenAccess() {
  try {
    _cg.lookupFunction<Bool Function(), bool Function()>('CGRequestScreenCaptureAccess')();
  } catch (_) {}
}

bool macHasAccessibility() {
  try {
    final hi = DynamicLibrary.open('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices');
    return hi.lookupFunction<Bool Function(), bool Function()>('AXIsProcessTrusted')();
  } catch (_) {
    return true;
  }
}

void macOpenAccessibilitySettings() {
  Process.run('open', ['x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility']);
}

class MacCapturer implements ScreenCapturer {
  Uint8List? _buf;

  @override
  RawFrame? capture({MonitorInfo? monitor}) {
    final id = int.tryParse(monitor?.id ?? '') ?? _mainDisplay();
    final img = _createImage(id);
    if (img == nullptr) return null;
    try {
      final w = _imgW(img), h = _imgH(img), bpr = _imgBpr(img);
      if (_imgBpp(img) != 32) return null;
      final data = _providerCopy(_imgProvider(img));
      if (data == nullptr) return null;
      try {
        final len = _dataLen(data);
        if (len < bpr * h) return null;
        if (_buf == null || _buf!.length != bpr * h) _buf = Uint8List(bpr * h);
        _buf!.setAll(0, _dataPtr(data).asTypedList(bpr * h));
      } finally {
        _cfRelease(data);
      }
      final f = RawFrame(w, h, bpr, _buf!, PixelFmt.bgra);
      final ev = _eventCreate(nullptr);
      if (ev != nullptr) {
        final p = _eventLocation(ev);
        _cfRelease(ev);
        final b = _displayBounds(id);
        final s = b.w > 0 ? w / b.w : 1.0;
        drawArrow(f, ((p.x - b.x) * s).round(), ((p.y - b.y) * s).round());
      }
      return f;
    } finally {
      _cfRelease(img);
    }
  }

  @override
  void dispose() {}
}

class MacInjector implements InputInjector {
  final Pointer<CGPoint> _pt = calloc<CGPoint>();
  final Set<int> _buttons = {};
  int _flags = 0;
  DateTime _lastClick = DateTime(0);
  int _clickCount = 0;
  double _lastX = -1, _lastY = -1;

  void _postAndRelease(Pointer<Void> ev) {
    if (ev == nullptr) return;
    _post(0 /* kCGHIDEventTap */, ev);
    _cfRelease(ev);
  }

  CGPoint _pos() => _pt.ref;

  @override
  void inject(InputEvent e, {MonitorInfo? monitor}) {
    switch (e) {
      case PointerMove(:final x, :final y):
        final b = _displayBounds(int.tryParse(monitor?.id ?? '') ?? _mainDisplay());
        _pt.ref
          ..x = b.x + x * b.w
          ..y = b.y + y * b.h;
        final type = _buttons.contains(Btn.left)
            ? 6
            : _buttons.contains(Btn.right)
                ? 7
                : _buttons.contains(Btn.middle)
                    ? 27
                    : 5;
        final ev = _mouseEvent(nullptr, type, _pos(), _buttons.contains(Btn.right) ? 1 : (_buttons.contains(Btn.middle) ? 2 : 0));
        if (ev != nullptr) _setFlags(ev, _flags);
        _postAndRelease(ev);
      case PointerButton(:final button, :final down):
        if (down) {
          _buttons.add(button);
          final now = DateTime.now();
          final p = _pos();
          final near = (p.x - _lastX).abs() < 5 && (p.y - _lastY).abs() < 5;
          _clickCount = (now.difference(_lastClick).inMilliseconds < 400 && near) ? _clickCount + 1 : 1;
          _lastClick = now;
          _lastX = p.x;
          _lastY = p.y;
        } else {
          _buttons.remove(button);
        }
        final type = switch (button) {
          Btn.right => down ? 3 : 4,
          Btn.middle => down ? 25 : 26,
          _ => down ? 1 : 2,
        };
        final ev = _mouseEvent(nullptr, type, _pos(), button == Btn.right ? 1 : (button == Btn.middle ? 2 : 0));
        if (ev != nullptr) {
          _setInt(ev, 1 /* kCGMouseEventClickState */, _clickCount);
          _setFlags(ev, _flags);
        }
        _postAndRelease(ev);
      case Scroll(:final dx, :final dy):
        _postAndRelease(_scrollEvent(nullptr, 0 /* pixel */, 2, (-dy * 40).round(), (-dx * 40).round(), 0));
      case KeyInput(:final hid, :final down):
        final kc = macKeyFor(hid);
        if (kc == null) return;
        final bit = isShift(hid)
            ? 0x20000
            : isCtrl(hid)
                ? 0x40000
                : isAlt(hid)
                    ? 0x80000
                    : isMeta(hid)
                        ? 0x100000
                        : 0;
        if (bit != 0) _flags = down ? (_flags | bit) : (_flags & ~bit);
        final ev = _keyEvent(nullptr, kc, down);
        if (ev != nullptr) _setFlags(ev, _flags);
        _postAndRelease(ev);
      case TextEntry(:final text):
        final units = text.codeUnits;
        final buf = calloc<Uint16>(2);
        try {
          for (final u in units) {
            for (final down in [true, false]) {
              final ev = _keyEvent(nullptr, 0, down);
              if (ev == nullptr) continue;
              buf[0] = u;
              _setUnicode(ev, 1, buf);
              _postAndRelease(ev);
            }
          }
        } finally {
          calloc.free(buf);
        }
      case PadState():
        break; // handled by GamepadInjector
      case SpecialAction():
        break;
    }
  }
}
