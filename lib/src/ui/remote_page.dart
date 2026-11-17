import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../client.dart';
import '../protocol.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../platform/theater.dart';
import '../stream/pcvr.dart';
import '../stream/rtc.dart';
import 'files_page.dart';
import 'gamepad.dart';
import 'theme.dart';
import '../platform/platform.dart';
import '../viewer_window.dart';

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

  // Game mode (WebRTC) + controllers + theater.
  RtcClient? _rtc;
  PadForwarder? _pads;
  bool _touchPad = false;
  bool _theater = false;
  bool _xr = false;

  // PC VR (SteamVR streaming to this headset).
  bool _pcvrAvailable = false;
  PcvrClient? _pcvr;
  RtcClient? _vrAudio;

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
    if (s.peerPads) {
      _pads = PadForwarder(s.send)..start();
    }
    if (s.peerRtc && widget.app.store.gameMode) {
      rtcUsable().then((ok) {
        if (ok && mounted) _startGameMode();
      });
    }
    if (s.peerVr) {
      PcvrClient.available().then((v) {
        if (mounted) setState(() => _pcvrAvailable = v);
      });
    }
    Theater.xrAvailable().then((v) {
      if (!mounted || !v) return;
      setState(() => _xr = true);
      _setTheater(true); // headsets open straight into the big screen
    });
  }

  GameModeSettings get _preset {
    final p = GameModeSettings.presets;
    return p[widget.app.store.gamePreset.clamp(0, p.length - 1)].$2;
  }

  Future<void> _startGameMode() async {
    if (!await rtcUsable()) {
      _snack('Game mode needs a working sound system (PulseAudio/PipeWire) on this device.');
      return;
    }
    final r = RtcClient(s.send);
    _rtc = r;
    s.onRtc = (m) => r.handle(m);
    var wasActive = false;
    r.addListener(() {
      if (!mounted) return;
      if (r.active && !wasActive) {
        wasActive = true;
        s.setStream(video: false); // hardware stream is up: stop the compatibility stream
      }
      if (r.error != null) {
        final e = r.error!;
        r.error = null;
        wasActive = false;
        s.setStream(video: true);
        _snack(e);
      }
      setState(() {});
    });
    await r.start(_preset.onMonitor(s.monitor?.osIndex));
    // Fall back if nothing arrives (e.g. UDP blocked between the networks).
    Future.delayed(const Duration(seconds: 15), () {
      if (mounted && _rtc == r && !r.active) {
        r.error = 'Game mode could not connect (UDP blocked?). Using compatibility mode.';
        r.stop();
      }
    });
  }

  Future<void> _startPcvr() async {
    final st = widget.app.store;
    final mbps = await showModalBottomSheet<int>(
      sheetAnimationStyle: dialogAnimation(),
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(
            title: Text('Play SteamVR games'),
            subtitle: Text('SteamVR starts on the PC and streams to this headset with head and controller tracking. '
                'Use 5 GHz/6 GHz Wi-Fi or a wired PC connection. Hold the left menu button for 3 seconds to leave.'),
          ),
          for (final b in const [50, 100, 150, 200])
            ListTile(
              leading: Icon(st.vrBitrate == b ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text('$b Mbps${b == 150 ? ' (recommended)' : b == 50 ? ' (weak Wi-Fi)' : ''}'),
              onTap: () => Navigator.pop(ctx, b),
            ),
        ]),
      ),
    );
    if (mbps == null) return;
    st.vrBitrate = mbps;
    await st.save();
    // Game audio rides the existing game-mode channel (audio only); video goes through SteamVR.
    if (_rtc != null) await _stopGameMode();
    if (s.peerRtc && await rtcUsable()) {
      final a = RtcClient(s.send);
      _vrAudio = a;
      s.onRtc = (m) => a.handle(m);
      await a.start(const GameModeSettings(video: false, fps: 30, bitrateKbps: 1000));
    }
    final c = PcvrClient(host: s.params.host, send: s.send, bitrateMbps: mbps);
    _pcvr = c;
    s.onVr = (m) => c.handle(m);
    c.events.listen((e) {
      if (!mounted) return;
      _snack(e);
      if (!c.active) _endPcvr();
    });
    await c.start();
  }

  Future<void> _endPcvr() async {
    _pcvr?.stop();
    _pcvr = null;
    s.onVr = null;
    final a = _vrAudio;
    _vrAudio = null;
    await a?.dispose();
    if (s.peerRtc && widget.app.store.gameMode && mounted) await _startGameMode();
  }

  Future<void> _stopGameMode() async {
    final r = _rtc;
    _rtc = null;
    s.onRtc = null;
    s.setStream(video: true);
    await r?.dispose();
    if (mounted) setState(() {});
  }

  Future<void> _setTheater(bool on) async {
    setState(() {
      _theater = on;
      _toolbar = !on;
    });
    final st = widget.app.store;
    final w = _rtc?.active == true ? _rtc!.renderer.videoWidth : s.image.value?.width ?? 16;
    final h = _rtc?.active == true ? _rtc!.renderer.videoHeight : s.image.value?.height ?? 9;
    if (on) {
      await Theater.enter(size: st.theaterSize, environment: st.theaterEnvironment, aspect: h > 0 ? w / h : 16 / 9);
    } else {
      await Theater.exit();
    }
  }

  Future<void> _theaterOptions() async {
    final st = widget.app.store;
    await showModalBottomSheet<void>(
      sheetAnimationStyle: dialogAnimation(),
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            const ListTile(title: Text('Screen size')),
            for (final e in theaterSizes.entries)
              ListTile(
                leading: Icon(st.theaterSize == e.key ? Icons.radio_button_checked : Icons.radio_button_off),
                title: Text(e.value.$1),
                onTap: () async {
                  st.theaterSize = e.key;
                  await st.save();
                  set(() {});
                  if (_theater) await _setTheater(true);
                },
              ),
            const Divider(),
            const ListTile(title: Text('Surroundings')),
            for (final e in theaterEnvironments.entries)
              ListTile(
                leading: Icon(st.theaterEnvironment == e.key ? Icons.radio_button_checked : Icons.radio_button_off),
                title: Text(e.value),
                onTap: () async {
                  st.theaterEnvironment = e.key;
                  await st.save();
                  set(() {});
                  await Theater.setEnvironment(e.key);
                },
              ),
          ]),
        ),
      ),
    );
  }

  Future<void> _gameModeOptions() async {
    final st = widget.app.store;
    final v = await showModalBottomSheet<int>(
      sheetAnimationStyle: dialogAnimation(),
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            title: const Text('Game mode quality'),
            subtitle: Text(s.peerRtc
                ? 'Hardware video (H.264) with sound, low latency. Higher settings need a fast network (5 GHz Wi-Fi or Ethernet).'
                : 'This host does not support game mode.'),
          ),
          for (var i = 0; i < GameModeSettings.presets.length; i++)
            ListTile(
              leading: Icon(st.gamePreset == i ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text(GameModeSettings.presets[i].$1),
              onTap: () => Navigator.pop(ctx, i),
            ),
        ]),
      ),
    );
    if (v == null) return;
    st.gamePreset = v;
    await st.save();
    if (s.peerRtc) {
      await _stopGameMode();
      await _startGameMode();
    }
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

  String _monitorLabel(MonitorInfo m) => m.isAll ? '${m.name} · ${m.w}×${m.h}' : '${m.name}${m.primary ? ' (main)' : ''} · ${m.w}×${m.h}';

  void _selectMonitor(String id) {
    s.selectMonitor(id);
    // Game mode streams the screen through WebRTC: restart it on the new monitor.
    final r = _rtc;
    if (r != null) unawaited(r.start(_preset.onMonitor(s.monitor?.osIndex)));
  }

  Future<void> _openMonitorWindow(String id) async {
    final m = s.monitors.firstWhere((x) => x.id == id, orElse: () => s.monitors.first);
    final ok = s.ticketId != null &&
        await openViewerWindow(ViewerLaunch(
          host: s.params.host,
          port: s.params.port,
          ticketId: s.ticketId!,
          ticketKey: s.ticketKey!,
          deviceName: s.peerName,
          deviceId: s.peerId,
          monitor: m.id,
          monitorName: m.name,
        ));
    if (!ok) _snack('Could not open a new window.');
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    _pads?.dispose();
    _pcvr?.stop();
    _vrAudio?.dispose();
    final r = _rtc;
    _rtc = null;
    r?.dispose();
    if (_theater) Theater.exit();
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
      final padKey = _pads != null && (k == LogicalKeyboardKey.gameButtonA || k == LogicalKeyboardKey.gameButtonB || k == LogicalKeyboardKey.gameButtonX);
      if (padKey) return KeyEventResult.handled; // forwarded as a controller instead
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
    if (_theater && e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.f11) {
      _setTheater(false);
      return KeyEventResult.handled;
    }
    final hid = e.physicalKey.usbHidUsage;
    if (hid == 0) return KeyEventResult.ignored;
    if (_pads != null && (hid >> 16) == 0x05) return KeyEventResult.handled; // gamepad page: sent as controller
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
      sheetAnimationStyle: dialogAnimation(),
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
                if (s.monitors.length > 1)
                  PopupMenuButton<String>(
                    tooltip: 'Monitor${s.monitor == null ? '' : ': ${s.monitor!.name}'}',
                    icon: const Icon(Icons.desktop_windows_outlined),
                    onSelected: (v) => v.startsWith('win:') ? _openMonitorWindow(v.substring(4)) : _selectMonitor(v),
                    itemBuilder: (_) => [
                      for (final m in s.monitors)
                        CheckedPopupMenuItem(value: m.id, checked: m.id == s.monitor?.id, child: Text(_monitorLabel(m))),
                      if (canOpenViewerWindows && s.ticketId != null && !widget.app.isTv) ...[
                        const PopupMenuDivider(),
                        for (final m in s.monitors.where((m) => !m.isAll))
                          PopupMenuItem(value: 'win:${m.id}', child: Text('Open ${m.name} in a new window')),
                      ],
                    ],
                  ),
                if (s.peerShares)
                  IconButton(
                    tooltip: 'Files',
                    icon: const Icon(Icons.folder_open),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FilesPage(session: s))),
                  ),
                if (s.peerRtc)
                  IconButton(
                    tooltip: _rtc?.active == true ? 'Game mode on (tap for quality)' : 'Game mode',
                    isSelected: _rtc?.active == true,
                    icon: const Icon(Icons.sports_esports_outlined),
                    selectedIcon: const Icon(Icons.sports_esports),
                    onPressed: _gameModeOptions,
                  ),
                if (_pcvrAvailable)
                  IconButton(
                    tooltip: 'Play SteamVR games (PC VR)',
                    isSelected: _pcvr != null,
                    icon: const Icon(Icons.view_in_ar_outlined),
                    selectedIcon: const Icon(Icons.view_in_ar),
                    onPressed: _pcvr == null ? _startPcvr : _endPcvr,
                  ),
                if (touchDevice && _pads != null)
                  IconButton(
                    tooltip: 'On-screen controller',
                    isSelected: _touchPad,
                    icon: const Icon(Icons.gamepad_outlined),
                    selectedIcon: const Icon(Icons.gamepad),
                    onPressed: () => setState(() => _touchPad = !_touchPad),
                  ),
                IconButton(
                  tooltip: _xr ? 'VR theater' : 'Theater mode (fullscreen)',
                  icon: Icon(_xr ? Icons.vrpano_outlined : Icons.fullscreen),
                  onPressed: () => _setTheater(!_theater),
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
                      case 'stats':
                        widget.app.store.showStreamStats = !widget.app.store.showStreamStats;
                        await widget.app.store.save();
                        setState(() {});
                      case 'theaterOpts':
                        await _theaterOptions();
                      case 'gameOff':
                        if (_rtc != null) {
                          await _stopGameMode();
                        } else {
                          await _startGameMode();
                        }
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
                    if (s.peerRtc)
                      PopupMenuItem(value: 'gameOff', child: Text(_rtc != null ? 'Switch to compatibility mode' : 'Switch to game mode')),
                    CheckedPopupMenuItem(value: 'stats', checked: widget.app.store.showStreamStats, child: const Text('Show stream stats')),
                    const PopupMenuItem(value: 'theaterOpts', child: Text('Theater size & surroundings…')),
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
                final rtc = _rtc;
                final rtcOn = rtc != null && rtc.active && rtc.renderer.videoWidth > 0;
                if (img == null && !rtcOn) {
                  return Center(child: busyIndicator());
                }
                final src = rtcOn
                    ? Size(rtc.renderer.videoWidth.toDouble(), rtc.renderer.videoHeight.toDouble())
                    : Size(img!.width.toDouble(), img.height.toDouble());
                final fit = applyBoxFit(BoxFit.contain, src, box.biggest);
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
                        Positioned.fill(
                          child: rtcOn
                              ? RTCVideoView(rtc.renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
                              : RawImage(image: img, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
                        ),
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
        if (_touchPad && _pads != null) Positioned.fill(child: TouchGamepad(forwarder: _pads!)),
        if (widget.app.store.showStreamStats)
          Positioned(
            left: 8,
            bottom: 8,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                child: Text(
                  _rtc?.active == true ? 'Game mode · ${_rtc!.stats}' : 'Compatibility mode',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
            ),
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
