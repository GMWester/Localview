import 'dart:convert';
import 'dart:typed_data';

/// Message types carried inside encrypted frames (first byte).
abstract final class Msg {
  static const ping = 0x01;
  static const pong = 0x02;
  static const screenInfo = 0x10;
  static const frame = 0x11;
  static const pointerMove = 0x20;
  static const pointerButton = 0x21;
  static const scroll = 0x22;
  static const key = 0x23;
  static const text = 0x24;
  static const special = 0x25;
  static const frameAck = 0x26;
  static const streamSettings = 0x27;
  static const refresh = 0x28;
  static const clipboard = 0x30;
  static const clipboardRequest = 0x32;
  static const bye = 0x3F;
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

class SpecialAction extends InputEvent {
  const SpecialAction(this.action);
  final int action;
  @override
  List<Object> toList() => [5, action];
}
