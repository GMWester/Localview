// Virtual game controllers on the host, so games see a real Xbox controller.
//  * Windows: ViGEmBus driver (bundled with the installer) via ViGEmClient
//    compiled into the runner (windows/runner/virtual_gamepad.cpp).
//  * Linux / SteamOS: /dev/uinput Xbox 360 device (SDL, Steam, Proton see it).
//  * Elsewhere: buttons and sticks are mapped to keyboard keys.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../protocol.dart';
import 'platform.dart';

abstract class VirtualPads {
  bool get available;
  String get description;
  void update(PadState s);
  void dispose();
}

VirtualPads createVirtualPads() {
  try {
    if (Platform.isWindows) {
      final p = _WinVigemPads();
      if (p.available) return p;
    }
    if (Platform.isLinux) {
      final p = _UinputPads();
      if (p.available) return p;
    }
  } catch (e) {
    debugPrint('virtual gamepad unavailable: $e');
  }
  return _NoPads();
}

class _NoPads implements VirtualPads {
  @override
  bool get available => false;
  @override
  String get description => Platform.isWindows
      ? 'Install the ViGEmBus driver (offered by the Localview installer) for controller support; using keyboard mapping.'
      : Platform.isLinux
          ? 'No access to /dev/uinput; using keyboard mapping. Install the .deb (adds a udev rule) or run: sudo setfacl -m u:\$USER:rw /dev/uinput'
          : 'This OS has no virtual controller API; controller input is mapped to keyboard keys.';
  @override
  void update(PadState s) {}
  @override
  void dispose() {}
}

// ------------------------------------------------------------------ Windows
class _WinVigemPads implements VirtualPads {
  _WinVigemPads() {
    final exe = DynamicLibrary.executable();
    _init = exe.lookupFunction<Int32 Function(), int Function()>('lv_pad_init');
    _update = exe.lookupFunction<Int32 Function(Int32, Uint16, Uint8, Uint8, Int16, Int16, Int16, Int16),
        int Function(int, int, int, int, int, int, int, int)>('lv_pad_update');
    _shutdown = exe.lookupFunction<Void Function(), void Function()>('lv_pad_shutdown');
    _ok = _init() == 0;
  }
  late final int Function() _init;
  late final int Function(int, int, int, int, int, int, int, int) _update;
  late final void Function() _shutdown;
  bool _ok = false;

  @override
  bool get available => _ok;
  @override
  String get description => 'Virtual Xbox 360 controllers (ViGEmBus)';
  @override
  void update(PadState s) => _update(s.pad, s.buttons, s.lt, s.rt, s.lx, s.ly, s.rx, s.ry);
  @override
  void dispose() => _shutdown();
}

// ------------------------------------------------------------------ Linux uinput
final DynamicLibrary _libc = DynamicLibrary.open(Platform.isLinux ? 'libc.so.6' : 'libc.dylib');
final _open = _libc.lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>('open');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final _write = _libc.lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr), int Function(int, Pointer<Uint8>, int)>('write');
final _ioctlInt = _libc.lookupFunction<Int32 Function(Int32, UnsignedLong, VarArgs<(Int32,)>), int Function(int, int, int)>('ioctl');
final _ioctlPtr = _libc
    .lookupFunction<Int32 Function(Int32, UnsignedLong, VarArgs<(Pointer<Uint8>,)>), int Function(int, int, Pointer<Uint8>)>('ioctl');
final _ioctl0 = _libc.lookupFunction<Int32 Function(Int32, UnsignedLong), int Function(int, int)>('ioctl');

const _uiSetEvBit = 0x40045564, _uiSetKeyBit = 0x40045565, _uiSetAbsBit = 0x40045567;
const _uiDevSetup = 0x405c5503, _uiAbsSetup = 0x401c5504, _uiDevCreate = 0x5501, _uiDevDestroy = 0x5502;
const _evSyn = 0, _evKey = 1, _evAbs = 3;

// XInput bit -> Linux button code (xpad layout).
const _btnMap = <int, int>{
  PadBtn.a: 0x130, PadBtn.b: 0x131, PadBtn.x: 0x133, PadBtn.y: 0x134,
  PadBtn.leftShoulder: 0x136, PadBtn.rightShoulder: 0x137,
  PadBtn.back: 0x13a, PadBtn.start: 0x13b, PadBtn.guide: 0x13c,
  PadBtn.leftThumb: 0x13d, PadBtn.rightThumb: 0x13e,
};

class _UinputPads implements VirtualPads {
  _UinputPads() {
    final probe = _openDevice(0);
    _ok = probe >= 0;
    if (_ok) _fds[0] = probe;
  }
  final Map<int, int> _fds = {};
  final Map<int, PadState> _last = {};
  bool _ok = false;
  final Pointer<Uint8> _ev = calloc<Uint8>(24 * 16);

  @override
  bool get available => _ok;
  @override
  String get description => 'Virtual Xbox 360 controllers (uinput)';

  static int _openDevice(int index) {
    final path = '/dev/uinput'.toNativeUtf8();
    final fd = _open(path, 1 | 0x800); // O_WRONLY | O_NONBLOCK
    calloc.free(path);
    if (fd < 0) return -1;
    _ioctlInt(fd, _uiSetEvBit, _evKey);
    _ioctlInt(fd, _uiSetEvBit, _evAbs);
    for (final code in _btnMap.values) {
      _ioctlInt(fd, _uiSetKeyBit, code);
    }
    final setup = calloc<Uint8>(92);
    final abs = calloc<Uint8>(28);
    try {
      void axis(int code, int min, int max, int flat) {
        _ioctlInt(fd, _uiSetAbsBit, code);
        ByteData.sublistView(abs.asTypedList(28))
          ..setUint16(0, code, Endian.host)
          ..setInt32(4, 0, Endian.host) // value
          ..setInt32(8, min, Endian.host)
          ..setInt32(12, max, Endian.host)
          ..setInt32(16, 16, Endian.host) // fuzz
          ..setInt32(20, flat, Endian.host)
          ..setInt32(24, 0, Endian.host);
        _ioctlPtr(fd, _uiAbsSetup, abs);
      }

      for (final c in [0x00, 0x01, 0x03, 0x04]) {
        axis(c, -32768, 32767, 128);
      }
      axis(0x02, 0, 255, 0); // ABS_Z  (left trigger)
      axis(0x05, 0, 255, 0); // ABS_RZ (right trigger)
      axis(0x10, -1, 1, 0); // hat x
      axis(0x11, -1, 1, 0); // hat y
      ByteData.sublistView(setup.asTypedList(92))
        ..setUint16(0, 0x03, Endian.host) // BUS_USB
        ..setUint16(2, 0x045e, Endian.host) // Microsoft
        ..setUint16(4, 0x028e, Endian.host) // Xbox 360 controller
        ..setUint16(6, 0x0110, Endian.host);
      final name = 'Localview Virtual Xbox 360 Controller ${index + 1}'.codeUnits;
      setup.asTypedList(92).setRange(8, 8 + name.length, name);
      if (_ioctlPtr(fd, _uiDevSetup, setup) < 0 || _ioctl0(fd, _uiDevCreate) < 0) {
        _close(fd);
        return -1;
      }
      return fd;
    } finally {
      calloc.free(setup);
      calloc.free(abs);
    }
  }

  @override
  void update(PadState s) {
    var fd = _fds[s.pad];
    if (fd == null) {
      fd = _openDevice(s.pad);
      if (fd < 0) return;
      _fds[s.pad] = fd;
    }
    final prev = _last[s.pad];
    _last[s.pad] = s;
    final evs = ByteData.sublistView(_ev.asTypedList(24 * 16));
    var n = 0;
    void ev(int type, int code, int value) {
      final o = n * 24; // struct input_event: timeval(16) type(2) code(2) value(4)
      evs.setUint64(o, 0, Endian.host);
      evs.setUint64(o + 8, 0, Endian.host);
      evs.setUint16(o + 16, type, Endian.host);
      evs.setUint16(o + 18, code, Endian.host);
      evs.setInt32(o + 20, value, Endian.host);
      n++;
    }

    _btnMap.forEach((bit, code) {
      final now = s.buttons & bit != 0;
      if (prev == null || (prev.buttons & bit != 0) != now) ev(_evKey, code, now ? 1 : 0);
    });
    int hat(int neg, int pos) => (s.buttons & pos != 0 ? 1 : 0) - (s.buttons & neg != 0 ? 1 : 0);
    ev(_evAbs, 0x00, s.lx);
    ev(_evAbs, 0x01, -s.ly.clamp(-32767, 32767));
    ev(_evAbs, 0x03, s.rx);
    ev(_evAbs, 0x04, -s.ry.clamp(-32767, 32767));
    ev(_evAbs, 0x02, s.lt);
    ev(_evAbs, 0x05, s.rt);
    ev(_evAbs, 0x10, hat(PadBtn.dpadLeft, PadBtn.dpadRight));
    ev(_evAbs, 0x11, hat(PadBtn.dpadUp, PadBtn.dpadDown));
    ev(_evSyn, 0, 0);
    _write(fd, _ev, n * 24);
  }

  @override
  void dispose() {
    for (final fd in _fds.values) {
      _ioctl0(fd, _uiDevDestroy);
      _close(fd);
    }
    _fds.clear();
  }
}

/// Wraps the desktop/Android injector: controller states go to virtual pads,
/// or are translated into keyboard keys when no virtual controller exists.
class GamepadInjector implements InputInjector {
  GamepadInjector(this.base, this.pads);
  final InputInjector? base;
  final VirtualPads pads;
  final Map<int, Set<int>> _keysDown = {};

  // Fallback layout: left stick / d-pad -> WASD + arrows, A Space, B Esc, X E, Y Q,
  // LB Shift, RB Ctrl, Start Enter, Back Tab, triggers -> mouse buttons? (kept as keys: LT R, RT F).
  static const _keyFor = <int, int>{
    PadBtn.a: 0x2C, PadBtn.b: 0x29, PadBtn.x: 0x08, PadBtn.y: 0x14,
    PadBtn.leftShoulder: 0xE1, PadBtn.rightShoulder: 0xE0, PadBtn.start: 0x28, PadBtn.back: 0x2B,
    PadBtn.dpadUp: 0x52, PadBtn.dpadDown: 0x51, PadBtn.dpadLeft: 0x50, PadBtn.dpadRight: 0x4F,
  };

  @override
  void inject(InputEvent e) {
    if (e is! PadState) {
      base?.inject(e);
      return;
    }
    if (pads.available) {
      pads.update(e);
      return;
    }
    final want = <int>{};
    _keyFor.forEach((bit, hid) {
      if (e.buttons & bit != 0) want.add(hid);
    });
    const dz = 12000;
    if (e.ly > dz) want.add(0x1A); // W
    if (e.ly < -dz) want.add(0x16); // S
    if (e.lx < -dz) want.add(0x04); // A
    if (e.lx > dz) want.add(0x07); // D
    if (e.lt > 100) want.add(0x15); // R
    if (e.rt > 100) want.add(0x09); // F
    final had = _keysDown[e.pad] ?? <int>{};
    for (final k in had.difference(want)) {
      base?.inject(KeyInput(0x00070000 | k, false));
    }
    for (final k in want.difference(had)) {
      base?.inject(KeyInput(0x00070000 | k, true));
    }
    _keysDown[e.pad] = want;
    // Right stick -> relative mouse look is not possible with absolute pointer events; ignored.
  }
}
