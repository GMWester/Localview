import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:gamepads/gamepads.dart';
import 'package:material_ui/material_ui.dart';

import '../protocol.dart';

/// Collects physical controllers (USB/Bluetooth, Steam Frame / Quest / TV
/// controllers that the OS exposes as gamepads) and the on-screen pad, and
/// sends Xbox-style states to the host.
class PadForwarder {
  PadForwarder(this.send);
  final void Function(Uint8List) send;
  StreamSubscription<NormalizedGamepadEvent>? _sub;
  final Map<String, int> _index = {};
  final Map<int, PadValues> _pads = {};
  int connected = 0;

  void start() {
    _sub = Gamepads.normalizedEvents.listen(_onEvent, onError: (_) {});
  }

  void _onEvent(NormalizedGamepadEvent e) {
    final i = _index.putIfAbsent(e.gamepadId, () => min(_index.length, 3));
    connected = _index.length;
    final p = _pads.putIfAbsent(i, PadValues.new);
    final v = e.value;
    if (e.button != null) {
      final bit = switch (e.button!) {
        GamepadButton.a => PadBtn.a,
        GamepadButton.b => PadBtn.b,
        GamepadButton.x => PadBtn.x,
        GamepadButton.y => PadBtn.y,
        GamepadButton.leftBumper => PadBtn.leftShoulder,
        GamepadButton.rightBumper => PadBtn.rightShoulder,
        GamepadButton.back => PadBtn.back,
        GamepadButton.start => PadBtn.start,
        GamepadButton.home => PadBtn.guide,
        GamepadButton.leftStick => PadBtn.leftThumb,
        GamepadButton.rightStick => PadBtn.rightThumb,
        GamepadButton.dpadUp => PadBtn.dpadUp,
        GamepadButton.dpadDown => PadBtn.dpadDown,
        GamepadButton.dpadLeft => PadBtn.dpadLeft,
        GamepadButton.dpadRight => PadBtn.dpadRight,
        GamepadButton.leftTrigger => -1,
        GamepadButton.rightTrigger => -2,
        _ => 0,
      };
      if (bit == -1) {
        p.lt = v > 0.5 ? 255 : 0;
      } else if (bit == -2) {
        p.rt = v > 0.5 ? 255 : 0;
      } else if (bit != 0) {
        p.buttons = v > 0.5 ? (p.buttons | bit) : (p.buttons & ~bit);
      }
    } else if (e.axis != null) {
      int stick(double x) => (x.clamp(-1.0, 1.0) * 32767).round();
      switch (e.axis!) {
        case GamepadAxis.leftStickX:
          p.lx = stick(v);
        case GamepadAxis.leftStickY:
          p.ly = stick(v);
        case GamepadAxis.rightStickX:
          p.rx = stick(v);
        case GamepadAxis.rightStickY:
          p.ry = stick(v);
        case GamepadAxis.leftTrigger:
          p.lt = (v.clamp(0.0, 1.0) * 255).round();
        case GamepadAxis.rightTrigger:
          p.rt = (v.clamp(0.0, 1.0) * 255).round();
      }
    }
    _flush(i, p);
  }

  void _flush(int i, PadValues p) {
    final st = PadState(i, p.buttons, p.lt, p.rt, p.lx, p.ly, p.rx, p.ry);
    send(st.encode());
  }

  /// State from the on-screen controller (always pad 0 unless a real one is connected).
  void setVirtual(PadValues p) => _flush(_index.isEmpty ? 0 : min(_index.length, 3), p);

  void dispose() => _sub?.cancel();
}

class PadValues {
  int buttons = 0, lt = 0, rt = 0, lx = 0, ly = 0, rx = 0, ry = 0;
}

/// Touch controller overlay for phones/tablets (Xbox layout).
class TouchGamepad extends StatefulWidget {
  const TouchGamepad({super.key, required this.forwarder});
  final PadForwarder forwarder;
  @override
  State<TouchGamepad> createState() => _TouchGamepadState();
}

class _TouchGamepadState extends State<TouchGamepad> {
  final PadValues _p = PadValues();

  void _set(int bit, bool down) {
    _p.buttons = down ? (_p.buttons | bit) : (_p.buttons & ~bit);
    widget.forwarder.setVirtual(_p);
  }

  Widget _btn(String label, int bit, {Color? color, double size = 56}) => _HoldButton(
        size: size,
        label: label,
        color: color,
        onChanged: (d) => _set(bit, d),
      );

  Widget _trigger(String label, bool left) => _HoldButton(
        size: 48,
        label: label,
        onChanged: (d) {
          if (left) {
            _p.lt = d ? 255 : 0;
          } else {
            _p.rt = d ? 255 : 0;
          }
          widget.forwarder.setVirtual(_p);
        },
      );

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: false,
      child: Stack(children: [
        Positioned(left: 16, top: 12, child: Row(children: [_trigger('LT', true), const SizedBox(width: 8), _btn('LB', PadBtn.leftShoulder, size: 48)])),
        Positioned(right: 16, top: 12, child: Row(children: [_btn('RB', PadBtn.rightShoulder, size: 48), const SizedBox(width: 8), _trigger('RT', false)])),
        Positioned(
          left: 24,
          bottom: 24,
          child: _Stick(onChanged: (x, y) {
            _p.lx = (x * 32767).round();
            _p.ly = (-y * 32767).round();
            widget.forwarder.setVirtual(_p);
          }),
        ),
        Positioned(
          left: 190,
          bottom: 20,
          child: Column(children: [
            _btn('▲', PadBtn.dpadUp, size: 40),
            Row(children: [_btn('◀', PadBtn.dpadLeft, size: 40), const SizedBox(width: 40), _btn('▶', PadBtn.dpadRight, size: 40)]),
            _btn('▼', PadBtn.dpadDown, size: 40),
          ]),
        ),
        Positioned(
          right: 190,
          bottom: 30,
          child: _Stick(
            size: 110,
            onChanged: (x, y) {
              _p.rx = (x * 32767).round();
              _p.ry = (-y * 32767).round();
              widget.forwarder.setVirtual(_p);
            },
          ),
        ),
        Positioned(
          right: 20,
          bottom: 24,
          child: SizedBox(
            width: 160,
            height: 160,
            child: Stack(children: [
              Align(alignment: Alignment.topCenter, child: _btn('Y', PadBtn.y, color: Colors.amber)),
              Align(alignment: Alignment.centerLeft, child: _btn('X', PadBtn.x, color: Colors.blue)),
              Align(alignment: Alignment.centerRight, child: _btn('B', PadBtn.b, color: Colors.red)),
              Align(alignment: Alignment.bottomCenter, child: _btn('A', PadBtn.a, color: Colors.green)),
            ]),
          ),
        ),
        Positioned(
          bottom: 16,
          left: 0,
          right: 0,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _btn('⧉', PadBtn.back, size: 40),
            const SizedBox(width: 16),
            _btn('⊙', PadBtn.guide, size: 40),
            const SizedBox(width: 16),
            _btn('≡', PadBtn.start, size: 40),
          ]),
        ),
      ]),
    );
  }
}

class _HoldButton extends StatefulWidget {
  const _HoldButton({required this.label, required this.onChanged, this.size = 56, this.color});
  final String label;
  final void Function(bool down) onChanged;
  final double size;
  final Color? color;
  @override
  State<_HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<_HoldButton> {
  bool _down = false;
  void _set(bool d) {
    if (d == _down) return;
    setState(() => _down = d);
    widget.onChanged(d);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color ?? Colors.white;
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: Container(
        width: widget.size,
        height: widget.size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c.withValues(alpha: _down ? 0.55 : 0.18),
          border: Border.all(color: c.withValues(alpha: 0.7), width: 2),
        ),
        child: Text(widget.label, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: widget.size * 0.32)),
      ),
    );
  }
}

class _Stick extends StatefulWidget {
  const _Stick({required this.onChanged, this.size = 130});
  final void Function(double x, double y) onChanged;
  final double size;
  @override
  State<_Stick> createState() => _StickState();
}

class _StickState extends State<_Stick> {
  Offset _knob = Offset.zero;

  void _update(Offset local) {
    final r = widget.size / 2;
    var d = local - Offset(r, r);
    if (d.distance > r) d = d / d.distance * r;
    setState(() => _knob = d);
    widget.onChanged(d.dx / r, d.dy / r);
  }

  void _reset() {
    setState(() => _knob = Offset.zero);
    widget.onChanged(0, 0);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return GestureDetector(
      onPanStart: (d) => _update(d.localPosition),
      onPanUpdate: (d) => _update(d.localPosition),
      onPanEnd: (_) => _reset(),
      onPanCancel: _reset,
      child: Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 2),
        ),
        child: Center(
          child: Transform.translate(
            offset: _knob,
            child: Container(
              width: s * 0.42,
              height: s * 0.42,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.45)),
            ),
          ),
        ),
      ),
    );
  }
}
