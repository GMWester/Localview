import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../client.dart';
import '../protocol.dart';
import 'files_page.dart';

class RemotePage extends StatefulWidget {
  const RemotePage({super.key, required this.app, required this.session});
  final AppController app;
  final ClientSession session;
  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> {
  ClientSession get s => widget.session;
  final FocusNode _focus = FocusNode();
  final FocusNode _typeFocus = FocusNode();
  final TextEditingController _type = TextEditingController(text: _sentinel);
  static const _sentinel = '  ';
  Rect _imageRect = Rect.zero;
  bool _toolbar = true;
  bool _virtualCursor = false;
  Offset _vc = const Offset(0.5, 0.5);
  int _vcSpeed = 0;
  bool _dragging = false;
  int _pointers = 0;
  Offset? _lastFocal;
  double _scrollAcc = 0;

  @override
  void initState() {
    super.initState();
    _virtualCursor = widget.app.isTv;
    s.addListener(_onSession);
    s.onClipboard = (t) {
      Clipboard.setData(ClipboardData(text: t));
      _snack('Remote clipboard copied to this device.');
    };
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _onSession() {
    if (s.closed && mounted) {
      if (s.error != null) _snack(s.error!);
      Navigator.of(context).maybePop();
    } else if (mounted) {
      setState(() {});
    }
  }

  void _snack(String t) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(t)));

  @override
  void dispose() {
    s.removeListener(_onSession);
    if (!s.closed) s.close();
    _focus.dispose();
    _typeFocus.dispose();
    super.dispose();
  }

  Offset? _norm(Offset local) {
    if (_imageRect.isEmpty) return null;
    final x = ((local.dx - _imageRect.left) / _imageRect.width).clamp(0.0, 1.0);
    final y = ((local.dy - _imageRect.top) / _imageRect.height).clamp(0.0, 1.0);
    return Offset(x, y);
  }

  void _move(Offset local) {
    final n = _norm(local);
    if (n != null) s.send(pointerMoveMsg(n.dx, n.dy));
  }

  void _btn(int b, bool down) => s.send(pointerButtonMsg(b, down));

  void _click(int b) {
    _btn(b, true);
    _btn(b, false);
  }

  // ------------------------------------------------------------------ mouse
  void _onPointerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    _move(e.localPosition);
    _btn(_mapButton(e.buttons), true);
  }

  int _lastMouseButtons = 0;
  int _mapButton(int buttons) {
    _lastMouseButtons = buttons;
    if (buttons & kSecondaryMouseButton != 0) return Btn.right;
    if (buttons & kMiddleMouseButton != 0) return Btn.middle;
    return Btn.left;
  }

  void _onPointerUp(PointerUpEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    _btn(_mapButton(_lastMouseButtons), false);
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      s.send(scrollMsg(e.scrollDelta.dx / 50, e.scrollDelta.dy / 50));
    }
  }

  // ------------------------------------------------------------------ touch
  void _onScaleStart(ScaleStartDetails d) {
    _pointers = d.pointerCount;
    _lastFocal = d.localFocalPoint;
    if (_pointers == 1 && !_virtualCursor) {
      _move(d.localFocalPoint);
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      if (_dragging) {
        _btn(Btn.left, false);
        _dragging = false;
      }
      final dy = d.localFocalPoint.dy - (_lastFocal?.dy ?? d.localFocalPoint.dy);
      _scrollAcc += -dy / 30;
      if (_scrollAcc.abs() >= 1) {
        s.send(scrollMsg(0, _scrollAcc.truncateToDouble()));
        _scrollAcc -= _scrollAcc.truncateToDouble();
      }
    } else if (_virtualCursor) {
      final delta = d.localFocalPoint - (_lastFocal ?? d.localFocalPoint);
      _nudge(Offset(delta.dx / _imageRect.width, delta.dy / _imageRect.height));
    } else {
      if (!_dragging) {
        _btn(Btn.left, true);
        _dragging = true;
      }
      _move(d.localFocalPoint);
    }
    _lastFocal = d.localFocalPoint;
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_dragging) {
      _btn(Btn.left, false);
      _dragging = false;
    }
  }

  void _onTapUp(TapUpDetails d) {
    if (_virtualCursor) {
      _click(Btn.left);
      return;
    }
    _move(d.localPosition);
    _click(Btn.left);
  }

  void _onLongPress(LongPressStartDetails d) {
    if (!_virtualCursor) _move(d.localPosition);
    _click(Btn.right);
  }

  // --------------------------------------------------------- virtual cursor (TV / D-pad / VR controllers)
  void _nudge(Offset delta) {
    setState(() => _vc = Offset((_vc.dx + delta.dx).clamp(0.0, 1.0), (_vc.dy + delta.dy).clamp(0.0, 1.0)));
    s.send(pointerMoveMsg(_vc.dx, _vc.dy));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (_virtualCursor) {
      final k = e.logicalKey;
      final isDown = e is KeyDownEvent || e is KeyRepeatEvent;
      double step() => 0.004 * (1 + (_vcSpeed++).clamp(0, 12));
      if (e is KeyUpEvent) _vcSpeed = 0;
      if (k == LogicalKeyboardKey.arrowLeft && isDown) { _nudge(Offset(-step(), 0)); return KeyEventResult.handled; }
      if (k == LogicalKeyboardKey.arrowRight && isDown) { _nudge(Offset(step(), 0)); return KeyEventResult.handled; }
      if (k == LogicalKeyboardKey.arrowUp && isDown) { _nudge(Offset(0, -step())); return KeyEventResult.handled; }
      if (k == LogicalKeyboardKey.arrowDown && isDown) { _nudge(Offset(0, step())); return KeyEventResult.handled; }
      if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.gameButtonA) {
        if (e is KeyDownEvent) _btn(Btn.left, true);
        if (e is KeyUpEvent) _btn(Btn.left, false);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.contextMenu || k == LogicalKeyboardKey.gameButtonX) {
        if (e is KeyDownEvent) _click(Btn.right);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.gameButtonB) {
        if (e is KeyDownEvent) setState(() => _toolbar = !_toolbar);
        return KeyEventResult.handled;
      }
    }
    final hid = e.physicalKey.usbHidUsage;
    if (hid == 0) return KeyEventResult.ignored;
    if (e is KeyDownEvent || e is KeyRepeatEvent) {
      s.send(keyMsg(hid, true));
    } else if (e is KeyUpEvent) {
      s.send(keyMsg(hid, false));
    }
    return KeyEventResult.handled;
  }

  // Soft keyboard (phones/tablets/headsets): diff against a sentinel string.
  void _onTyped(String v) {
    if (v.length < _sentinel.length) {
      for (var i = 0; i < _sentinel.length - v.length; i++) {
        s.send(keyMsg(0x0007002A, true));
        s.send(keyMsg(0x0007002A, false));
      }
    } else if (v.length > _sentinel.length) {
      s.send(textMsg(Msg.text, v.substring(_sentinel.length)));
    }
    _type.value = const TextEditingValue(text: _sentinel, selection: TextSelection.collapsed(offset: 2));
  }

  void _combo(List<int> hids) {
    for (final h in hids) {
      s.send(keyMsg(0x00070000 | h, true));
    }
    for (final h in hids.reversed) {
      s.send(keyMsg(0x00070000 | h, false));
    }
  }

  Future<void> _quality() async {
    final v = await showModalBottomSheet<(double, int)>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final o in const [
            ('Best (100%, 30 fps)', 1.0, 30),
            ('Smooth (100%, 60 fps)', 1.0, 60),
            ('Balanced (75%, 30 fps)', 0.75, 30),
            ('Data saver (50%, 15 fps)', 0.5, 15),
          ])
            ListTile(title: Text(o.$1), onTap: () => Navigator.pop(ctx, (o.$2, o.$3))),
        ]),
      ),
    );
    if (v != null) s.setStream(scale: v.$1, fps: v.$2);
  }

  @override
  Widget build(BuildContext context) {
    final isAndroidPeer = s.peerOs == 'android';
    final touchDevice = Platform.isAndroid || Platform.isIOS;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _toolbar
          ? AppBar(
              title: Text(s.peerName, overflow: TextOverflow.ellipsis),
              actions: [
                if (touchDevice)
                  IconButton(
                    tooltip: 'Keyboard',
                    icon: const Icon(Icons.keyboard),
                    onPressed: () {
                      _typeFocus.requestFocus();
                      SystemChannels.textInput.invokeMethod('TextInput.show');
                    },
                  ),
                IconButton(
                  tooltip: 'Virtual cursor (D-pad / controller)',
                  isSelected: _virtualCursor,
                  icon: const Icon(Icons.mouse_outlined),
                  selectedIcon: const Icon(Icons.mouse),
                  onPressed: () => setState(() => _virtualCursor = !_virtualCursor),
                ),
                if (isAndroidPeer) ...[
                  IconButton(tooltip: 'Back', icon: const Icon(Icons.arrow_back), onPressed: () => s.send(specialMsg(Special.back))),
                  IconButton(tooltip: 'Home', icon: const Icon(Icons.circle_outlined), onPressed: () => s.send(specialMsg(Special.home))),
                  IconButton(tooltip: 'Recents', icon: const Icon(Icons.crop_square), onPressed: () => s.send(specialMsg(Special.recents))),
                ],
                if (s.peerShares)
                  IconButton(
                    tooltip: 'Files',
                    icon: const Icon(Icons.folder_open),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FilesPage(session: s))),
                  ),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    switch (v) {
                      case 'quality':
                        await _quality();
                      case 'clipSend':
                        final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
                        if (t != null) s.sendClipboard(t);
                      case 'clipGet':
                        s.requestClipboard();
                      case 'win':
                        _combo([0xE3]);
                      case 'alttab':
                        _combo([0xE2, 0x2B]);
                      case 'taskmgr':
                        _combo([0xE0, 0xE1, 0x29]);
                      case 'esc':
                        _combo([0x29]);
                      case 'refresh':
                        s.send(Uint8List.fromList([Msg.refresh]));
                      case 'hide':
                        setState(() => _toolbar = false);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'quality', child: Text('Stream quality…')),
                    const PopupMenuItem(value: 'clipSend', child: Text('Send my clipboard')),
                    const PopupMenuItem(value: 'clipGet', child: Text('Get remote clipboard')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'win', child: Text('Windows / Command key')),
                    const PopupMenuItem(value: 'alttab', child: Text('Alt + Tab')),
                    const PopupMenuItem(value: 'taskmgr', child: Text('Ctrl + Shift + Esc')),
                    const PopupMenuItem(value: 'esc', child: Text('Esc')),
                    const PopupMenuItem(value: 'refresh', child: Text('Refresh screen')),
                    const PopupMenuItem(value: 'hide', child: Text('Hide toolbar (Back / B to show)')),
                  ],
                ),
                IconButton(tooltip: 'Disconnect', icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
              ],
            )
          : null,
      body: Stack(children: [
        Positioned(
          left: 0,
          top: 0,
          width: 1,
          height: 1,
          child: Opacity(
            opacity: 0,
            child: TextField(
              focusNode: _typeFocus,
              controller: _type,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.text,
              onChanged: _onTyped,
              onSubmitted: (_) {
                _combo([0x28]);
                _typeFocus.requestFocus();
              },
            ),
          ),
        ),
        Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: LayoutBuilder(builder: (context, box) {
            return ValueListenableBuilder<ui.Image?>(
              valueListenable: s.image,
              builder: (context, img, _) {
                if (img == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final fit = applyBoxFit(BoxFit.contain, Size(img.width.toDouble(), img.height.toDouble()), box.biggest);
                _imageRect = Alignment.center.inscribe(fit.destination, Offset.zero & box.biggest);
                return MouseRegion(
                  cursor: _virtualCursor ? SystemMouseCursors.basic : SystemMouseCursors.none,
                  child: Listener(
                    onPointerHover: (e) => _virtualCursor ? null : _move(e.localPosition),
                    onPointerMove: (e) => e.kind == PointerDeviceKind.mouse ? _move(e.localPosition) : null,
                    onPointerDown: _onPointerDown,
                    onPointerUp: _onPointerUp,
                    onPointerSignal: _onSignal,
                    child: GestureDetector(
                      supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus},
                      onTapUp: _onTapUp,
                      onLongPressStart: _onLongPress,
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                      onScaleEnd: _onScaleEnd,
                      child: Stack(children: [
                        Positioned.fill(child: RawImage(image: img, fit: BoxFit.contain, filterQuality: FilterQuality.medium)),
                        if (_virtualCursor)
                          Positioned(
                            left: _imageRect.left + _vc.dx * _imageRect.width - 2,
                            top: _imageRect.top + _vc.dy * _imageRect.height - 2,
                            child: const IgnorePointer(child: Icon(Icons.navigation, color: Colors.amber, size: 28)),
                          ),
                      ]),
                    ),
                  ),
                );
              },
            );
          }),
        ),
        if (!_toolbar)
          Positioned(
            right: 8,
            top: MediaQuery.paddingOf(context).top + 8,
            child: IconButton.filledTonal(icon: const Icon(Icons.menu), onPressed: () => setState(() => _toolbar = true)),
          ),
      ]),
    );
  }
}
