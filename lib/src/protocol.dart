import 'dart:convert';
import 'dart:typed_data';

/// Message types carried inside encrypted frames (first byte).
abstract final class Msg {
  static const ping = 0x01;
  static const pong = 0x02;
  static const screenInfo = 0x10;
  static const frame = 0x11;
  /// Host -> viewer: one complete JPEG screen image (hosts that compress natively, i.e. Android).
  static const frameJpeg = 0x13;
  /// Host -> viewer: {list: [MonitorInfo json], current: id}
  static const monitors = 0x12;
  static const pointerMove = 0x20;
  static const pointerButton = 0x21;
  static const scroll = 0x22;
  static const key = 0x23;
  static const text = 0x24;
  static const special = 0x25;
  static const frameAck = 0x26;
  static const streamSettings = 0x27;
  static const refresh = 0x28;
  /// Viewer -> host: {id} (MonitorInfo.id; 'all' = whole desktop)
  static const selectMonitor = 0x29;
  /// Viewer -> host: {mode: portrait | landscape | auto} (Android hosts)
  static const rotate = 0x2A;
  /// Host -> viewer: {mode, error?}
  static const rotateResult = 0x2B;
  static const clipboard = 0x30;
  static const clipboardRequest = 0x32;
  static const bye = 0x3F;

  // Game mode (WebRTC hardware video + audio). Signaling travels inside the
  // encrypted session, so the DTLS fingerprints are authenticated end to end.
  static const rtcRequest = 0x50;
  static const rtcOffer = 0x51;
  static const rtcAnswer = 0x52;
  static const rtcIce = 0x53;
  static const rtcStop = 0x54;
  static const rtcError = 0x55;
  /// Viewer -> host: {mode: 'host' | 'viewer'} - where the sound plays (only there).
  static const audioRoute = 0x56;
  /// Host -> viewer: {mode, error?}
  static const audioRouteResult = 0x57;
  /// Host -> viewer: [type][PCM s16le stereo 48 kHz] - the sound of an Android host (no WebRTC there).
  static const audioPcm = 0x58;
  /// Viewer -> host (Android): {on} - display panel off while it is being controlled, or back on.
  static const screenPower = 0x59;
  /// Host -> viewer: {mode: 'off' | 'dim' | 'on', error?}
  static const screenPowerResult = 0x5A;

  /// Gamepad state: [type][pad][u16 buttons][u8 lt][u8 rt][i16 lx][i16 ly][i16 rx][i16 ry] (XInput layout).
  static const gamepad = 0x60;

  static bool isRtc(int t) => t >= 0x50 && t <= 0x5F;

  // PC VR (SteamVR -> headset). Control messages only; media flows over the
  // driver's own encrypted UDP link whose key is delivered in vrReady.
  static const vrStart = 0x70; // headset -> PC: display description
  static const vrReady = 0x71; // PC -> headset: {port, key}
  static const vrError = 0x72; // PC -> headset: {error}
  static const vrStop = 0x73; // headset -> PC
  static bool isVr(int t) => t >= 0x70 && t <= 0x7F;
}

/// XInput button bits.
abstract final class PadBtn {
  static const dpadUp = 0x0001, dpadDown = 0x0002, dpadLeft = 0x0004, dpadRight = 0x0008;
  static const start = 0x0010, back = 0x0020, leftThumb = 0x0040, rightThumb = 0x0080;
  static const leftShoulder = 0x0100, rightShoulder = 0x0200, guide = 0x0400;
  static const a = 0x1000, b = 0x2000, x = 0x4000, y = 0x8000;
}

/// Mouse buttons.
abstract final class Btn {
  static const left = 0;
  static const right = 1;
  static const middle = 2;
}

/// Special actions (mostly for Android hosts).
abstract final class Special {
  static const back = 1;
  static const home = 2;
  static const recents = 3;
  static const notifications = 4;
}

abstract final class PixelFmt {
  static const bgra = 0;
  static const rgba = 1;
}

Uint8List jsonMsg(int type, Map<String, dynamic> obj) {
  final body = utf8.encode(jsonEncode(obj));
  final out = Uint8List(body.length + 1);
  out[0] = type;
  out.setRange(1, out.length, body);
  return out;
}

Map<String, dynamic> jsonBody(Uint8List msg) =>
    (jsonDecode(utf8.decode(Uint8List.sublistView(msg, 1))) as Map).cast<String, dynamic>();

Uint8List textMsg(int type, String s) {
  final body = utf8.encode(s);
  final out = Uint8List(body.length + 1);
  out[0] = type;
  out.setRange(1, out.length, body);
  return out;
}

String textBody(Uint8List msg) => utf8.decode(Uint8List.sublistView(msg, 1), allowMalformed: true);

Uint8List pointerMoveMsg(double x, double y) {
  final b = ByteData(9)
    ..setUint8(0, Msg.pointerMove)
    ..setFloat32(1, x)
    ..setFloat32(5, y);
  return b.buffer.asUint8List();
}

Uint8List pointerButtonMsg(int button, bool down) => Uint8List.fromList([Msg.pointerButton, button, down ? 1 : 0]);

Uint8List scrollMsg(double dx, double dy) {
  final b = ByteData(9)
    ..setUint8(0, Msg.scroll)
    ..setFloat32(1, dx)
    ..setFloat32(5, dy);
  return b.buffer.asUint8List();
}

Uint8List keyMsg(int hidUsage, bool down) {
  final b = ByteData(6)
    ..setUint8(0, Msg.key)
    ..setUint32(1, hidUsage)
    ..setUint8(5, down ? 1 : 0);
  return b.buffer.asUint8List();
}

Uint8List specialMsg(int action) => Uint8List.fromList([Msg.special, action]);

/// Input event decoded on the host, as passed to the platform injector.
sealed class InputEvent {
  const InputEvent();

  static InputEvent? decode(Uint8List m) {
    if (m.isEmpty) return null;
    final b = ByteData.sublistView(m);
    switch (m[0]) {
      case Msg.pointerMove when m.length >= 9:
        return PointerMove(b.getFloat32(1).clamp(0.0, 1.0), b.getFloat32(5).clamp(0.0, 1.0));
      case Msg.pointerButton when m.length >= 3:
        return PointerButton(m[1], m[2] != 0);
      case Msg.scroll when m.length >= 9:
        return Scroll(b.getFloat32(1), b.getFloat32(5));
      case Msg.key when m.length >= 6:
        return KeyInput(b.getUint32(1), m[5] != 0);
      case Msg.text:
        return TextEntry(textBody(m));
      case Msg.special when m.length >= 2:
        return SpecialAction(m[1]);
      case Msg.gamepad when m.length >= 14:
        return PadState(m[1] & 3, b.getUint16(2), m[4], m[5], b.getInt16(6), b.getInt16(8), b.getInt16(10), b.getInt16(12));
    }
    return null;
  }

  /// Compact list form used to pass events between isolates.
  List<Object> toList();

  static InputEvent fromList(List<Object?> l) => switch (l[0]) {
        0 => PointerMove(l[1] as double, l[2] as double),
        1 => PointerButton(l[1] as int, l[2] as bool),
        2 => Scroll(l[1] as double, l[2] as double),
        3 => KeyInput(l[1] as int, l[2] as bool),
        4 => TextEntry(l[1] as String),
        6 => PadState(l[1] as int, l[2] as int, l[3] as int, l[4] as int, l[5] as int, l[6] as int, l[7] as int, l[8] as int),
        _ => SpecialAction(l[1] as int),
      };
}

class PointerMove extends InputEvent {
  const PointerMove(this.x, this.y);
  final double x, y;
  @override
  List<Object> toList() => [0, x, y];
}

class PointerButton extends InputEvent {
  const PointerButton(this.button, this.down);
  final int button;
  final bool down;
  @override
  List<Object> toList() => [1, button, down];
}

class Scroll extends InputEvent {
  const Scroll(this.dx, this.dy);

  /// In "lines"; positive dy scrolls content down (wheel towards user).
  final double dx, dy;
  @override
  List<Object> toList() => [2, dx, dy];
}

class KeyInput extends InputEvent {
  const KeyInput(this.hid, this.down);

  /// USB HID usage (page 7 in the low 16 bits, as Flutter's PhysicalKeyboardKey.usbHidUsage).
  final int hid;
  final bool down;
  @override
  List<Object> toList() => [3, hid, down];
}

class TextEntry extends InputEvent {
  const TextEntry(this.text);
  final String text;
  @override
  List<Object> toList() => [4, text];
}

/// Full state of one virtual Xbox-style controller.
class PadState extends InputEvent {
  const PadState(this.pad, this.buttons, this.lt, this.rt, this.lx, this.ly, this.rx, this.ry);
  final int pad, buttons, lt, rt, lx, ly, rx, ry;

  Uint8List encode() {
    final b = ByteData(14)
      ..setUint8(0, Msg.gamepad)
      ..setUint8(1, pad)
      ..setUint16(2, buttons)
      ..setUint8(4, lt)
      ..setUint8(5, rt)
      ..setInt16(6, lx)
      ..setInt16(8, ly)
      ..setInt16(10, rx)
      ..setInt16(12, ry);
    return b.buffer.asUint8List();
  }

  @override
  List<Object> toList() => [6, pad, buttons, lt, rt, lx, ly, rx, ry];
}

class SpecialAction extends InputEvent {
  const SpecialAction(this.action);
  final int action;
  @override
  List<Object> toList() => [5, action];
}
