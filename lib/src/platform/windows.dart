// Windows: GDI capture (BitBlt) and SendInput injection via dart:ffi.
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../codec.dart';
import '../protocol.dart';
import 'keymap.dart';
import 'platform.dart';

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final DynamicLibrary _gdi32 = DynamicLibrary.open('gdi32.dll');

final _getSystemMetrics = _user32.lookupFunction<Int32 Function(Int32), int Function(int)>('GetSystemMetrics');
final _getDC = _user32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GetDC');
final _releaseDC = _user32.lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>('ReleaseDC');
final _getCursorInfo = _user32.lookupFunction<Int32 Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>('GetCursorInfo');
final _getIconInfo =
    _user32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>('GetIconInfo');
final _drawIconEx = _user32.lookupFunction<
    Int32 Function(IntPtr, Int32, Int32, IntPtr, Int32, Int32, Uint32, IntPtr, Uint32),
    int Function(int, int, int, int, int, int, int, int, int)>('DrawIconEx');
final _sendInput =
    _user32.lookupFunction<Uint32 Function(Uint32, Pointer<Uint8>, Int32), int Function(int, Pointer<Uint8>, int)>('SendInput');
final _createCompatibleDC = _gdi32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('CreateCompatibleDC');
final _createDIBSection = _gdi32.lookupFunction<
    IntPtr Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Pointer<Uint8>>, IntPtr, Uint32),
    int Function(int, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, int, int)>('CreateDIBSection');
final _selectObject = _gdi32.lookupFunction<IntPtr Function(IntPtr, IntPtr), int Function(int, int)>('SelectObject');
final _deleteObject = _gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteObject');
final _deleteDC = _gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC');
final _bitBlt = _gdi32.lookupFunction<Int32 Function(IntPtr, Int32, Int32, Int32, Int32, IntPtr, Int32, Int32, Uint32),
    int Function(int, int, int, int, int, int, int, int, int)>('BitBlt');

const _srccopy = 0x00CC0020;
const _captureblt = 0x40000000;

class WinCapturer implements ScreenCapturer {
  WinCapturer() {
    _screenDC = _getDC(0);
    _memDC = _createCompatibleDC(_screenDC);
  }

  late final int _screenDC;
  late final int _memDC;
  int _bmp = 0, _old = 0, _w = 0, _h = 0;
  Pointer<Uint8> _bits = nullptr;
  final Pointer<Uint8> _ci = calloc<Uint8>(32);
  final Pointer<Uint8> _ii = calloc<Uint8>(40);

  void _ensure(int w, int h) {
    if (w == _w && h == _h && _bmp != 0) return;
    if (_bmp != 0) {
      _selectObject(_memDC, _old);
      _deleteObject(_bmp);
    }
    final bmi = calloc<Uint8>(44);
    final v = ByteData(44)
      ..setUint32(0, 40, Endian.little)
      ..setInt32(4, w, Endian.little)
      ..setInt32(8, -h, Endian.little) // top-down
      ..setUint16(12, 1, Endian.little)
      ..setUint16(14, 32, Endian.little);
    bmi.asTypedList(44).setAll(0, v.buffer.asUint8List());
    final pBits = calloc<Pointer<Uint8>>();
    _bmp = _createDIBSection(_screenDC, bmi, 0, pBits, 0, 0);
    _bits = pBits.value;
    calloc.free(pBits);
    calloc.free(bmi);
    if (_bmp == 0) throw StateError('CreateDIBSection failed');
    _old = _selectObject(_memDC, _bmp);
    _w = w;
    _h = h;
  }

  @override
  RawFrame? capture() {
    final w = _getSystemMetrics(0), h = _getSystemMetrics(1);
    if (w <= 0 || h <= 0) return null;
    _ensure(w, h);
    if (_bitBlt(_memDC, 0, 0, w, h, _screenDC, 0, 0, _srccopy | _captureblt) == 0) return null;
    _drawCursor();
    return RawFrame(w, h, w * 4, _bits.asTypedList(w * h * 4), PixelFmt.bgra);
  }

  void _drawCursor() {
    final ci = _ci.asTypedList(32);
    ci.fillRange(0, 32, 0);
    ByteData.sublistView(ci).setUint32(0, 24, Endian.little); // cbSize (x64)
    if (_getCursorInfo(_ci) == 0) return;
    final bd = ByteData.sublistView(ci);
    final flags = bd.getUint32(4, Endian.little);
    if (flags & 1 == 0) return; // CURSOR_SHOWING
    final hCursor = bd.getInt64(8, Endian.little);
    var x = bd.getInt32(16, Endian.little), y = bd.getInt32(20, Endian.little);
    if (_getIconInfo(hCursor, _ii) != 0) {
      final ib = ByteData.sublistView(_ii.asTypedList(40));
      x -= ib.getUint32(4, Endian.little);
      y -= ib.getUint32(8, Endian.little);
      final mask = ib.getInt64(16, Endian.little), color = ib.getInt64(24, Endian.little);
      if (mask != 0) _deleteObject(mask);
      if (color != 0) _deleteObject(color);
    }
    _drawIconEx(_memDC, x, y, hCursor, 0, 0, 0, 0, 3 /* DI_NORMAL */);
  }

  @override
  void dispose() {
    if (_bmp != 0) {
      _selectObject(_memDC, _old);
      _deleteObject(_bmp);
    }
    _deleteDC(_memDC);
    _releaseDC(0, _screenDC);
    calloc.free(_ci);
    calloc.free(_ii);
  }
}

class WinInjector implements InputInjector {
  final Pointer<Uint8> _in = calloc<Uint8>(40);
  double _accX = 0, _accY = 0;

  ByteData _clear() {
    final l = _in.asTypedList(40)..fillRange(0, 40, 0);
    return ByteData.sublistView(l);
  }

  void _mouse(int dx, int dy, int data, int flags) {
    _clear()
      ..setUint32(0, 0, Endian.little) // INPUT_MOUSE
      ..setInt32(8, dx, Endian.little)
      ..setInt32(12, dy, Endian.little)
      ..setUint32(16, data, Endian.little)
      ..setUint32(20, flags, Endian.little);
    _sendInput(1, _in, 40);
  }

  void _key(int vk, int scan, int flags) {
    _clear()
      ..setUint32(0, 1, Endian.little) // INPUT_KEYBOARD
      ..setUint16(8, vk, Endian.little)
      ..setUint16(10, scan, Endian.little)
      ..setUint32(12, flags, Endian.little);
    _sendInput(1, _in, 40);
  }

  @override
  void inject(InputEvent e) {
    switch (e) {
      case PointerMove(:final x, :final y):
        _mouse((x * 65535).round(), (y * 65535).round(), 0, 0x0001 | 0x8000);
      case PointerButton(:final button, :final down):
        final f = switch (button) {
          Btn.right => down ? 0x0008 : 0x0010,
          Btn.middle => down ? 0x0020 : 0x0040,
          _ => down ? 0x0002 : 0x0004,
        };
        _mouse(0, 0, 0, f);
      case Scroll(:final dx, :final dy):
        _accY += dy * 120;
        _accX += dx * 120;
        final iy = _accY.truncate(), ix = _accX.truncate();
        if (iy != 0) {
          _mouse(0, 0, (-iy) & 0xFFFFFFFF, 0x0800);
          _accY -= iy;
        }
        if (ix != 0) {
          _mouse(0, 0, ix & 0xFFFFFFFF, 0x1000);
          _accX -= ix;
        }
      case KeyInput(:final hid, :final down):
        final sc = winScanFor(hid);
        if (sc == null) return;
        var flags = 0x0008; // SCANCODE
        if (sc & 0xE000 == 0xE000) flags |= 0x0001;
        if (!down) flags |= 0x0002;
        _key(0, sc & 0xFF, flags);
      case TextEntry(:final text):
        for (final u in text.codeUnits) {
          if (u == 10 || u == 13) {
            _key(0, 0x1C, 0x0008);
            _key(0, 0x1C, 0x000A);
            continue;
          }
          _key(0, u, 0x0004);
          _key(0, u, 0x0006);
        }
      case SpecialAction():
        break;
    }
  }
}
