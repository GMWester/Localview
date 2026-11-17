import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../config.dart';
import '../platform/android.dart';
import '../platform/macos.dart' as mac;
import '../updater.dart';
import 'two_factor.dart';
import 'theme.dart';

class ThisDevicePage extends StatefulWidget {
  const ThisDevicePage({super.key, required this.app});
  final AppController app;
  @override
  State<ThisDevicePage> createState() => _ThisDevicePageState();
}

class _ThisDevicePageState extends State<ThisDevicePage> {
  bool? _capturing, _a11y, _files, _macScreen, _macA11y;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    _refreshPerms();
  }

  Future<void> _refreshPerms() async {
    if (Platform.isAndroid) {
      _capturing = await AndroidBridge.isCapturing();
      _a11y = await AndroidBridge.accessibilityEnabled();
      _files = await AndroidBridge.hasAllFilesAccess();
    }
    if (Platform.isMacOS) {
      _macScreen = mac.macHasScreenAccess();
      _macA11y = mac.macHasAccessibility();
    }
    if (mounted) setState(() {});
  }

  Future<void> _setPassword() async {
    final a = TextEditingController(), b = TextEditingController();
    final ok = await showDialog<bool>(
      animationStyle: dialogAnimation(),
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set device password'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Other devices must enter this password to connect to this one.'),
          const SizedBox(height: 12),
          TextField(controller: a, obscureText: true, autofocus: true,
              decoration: const InputDecoration(labelText: 'New password', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: b, obscureText: true,
              onSubmitted: (_) => Navigator.pop(ctx, true),
              decoration: const InputDecoration(labelText: 'Repeat password', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          const Text('You can look it up later on this device with the eye button.', style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final m = ScaffoldMessenger.of(context);
    if (a.text.length < 6) {
      m.showSnackBar(const SnackBar(content: Text('Use at least 6 characters.')));
      return;
    }
    if (a.text != b.text) {
      m.showSnackBar(const SnackBar(content: Text('Passwords do not match.')));
      return;
    }
    await app.store.setPassword(a.text);
    m.showSnackBar(const SnackBar(content: Text('Password saved.')));
  }

  Future<void> _showPassword() async {
    final pw = app.store.password;
    await showDialog<void>(
      animationStyle: dialogAnimation(),
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('This device\'s password'),
        content: pw == null
            ? const Text('This password was set before Localview could remember it. Use Change to set a new one.')
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Type this on the other device to connect to this one.'),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(pw, style: const TextStyle(fontSize: 20, fontFamily: 'monospace', letterSpacing: 1)),
                ),
                const SizedBox(height: 12),
                Text('Only visible here, on this device. It is never sent to other devices.',
                    style: Theme.of(ctx).textTheme.bodySmall),
              ]),
        actions: [
          if (pw != null)
            TextButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copy'),
              onPressed: () => Clipboard.setData(ClipboardData(text: pw)),
            ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _rename() async {
    final c = TextEditingController(text: app.store.deviceName);
    final v = await showDialog<String>(
      animationStyle: dialogAnimation(),
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Device name'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (v == null || v.trim().isEmpty) return;
    app.store.deviceName = v.trim();
    await app.store.save();
  }

  Widget _perm(String title, bool? ok, VoidCallback fix, String fixLabel) => ListTile(
        leading: Icon(ok == true ? Icons.check_circle : Icons.error_outline, color: ok == true ? Colors.green : Colors.orange),
        title: Text(title),
        trailing: ok == true ? null : TextButton(onPressed: fix, child: Text(fixLabel)),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app, app.store]),
      builder: (context, _) {
        final s = app.store;
        final h = app.host;
        final port = h.boundPort ?? s.tcpPort;
        final tt = Theme.of(context).textTheme;
        return ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: Text(s.deviceName, style: tt.titleMedium),
                subtitle: Text('$kOsName · ID ${s.deviceId.substring(0, 8)}'),
                trailing: IconButton(icon: const Icon(Icons.edit), onPressed: _rename),
              ),
              ListTile(
                leading: const Icon(Icons.password),
                title: const Text('Password'),
                subtitle: Text(s.hasPassword ? 'Set — other devices need it to connect' : 'Not set — nobody can connect yet'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (s.hasPassword)
                    IconButton(tooltip: 'Show password', icon: const Icon(Icons.visibility_outlined), onPressed: _showPassword),
                  FilledButton.tonal(onPressed: _setPassword, child: Text(s.hasPassword ? 'Change' : 'Set password')),
                ]),
              ),
              ListTile(
                leading: Icon(s.totpEnabled ? Icons.verified_user : Icons.verified_user_outlined,
                    color: s.totpEnabled ? Colors.green : null),
                title: const Text('Two-factor authentication'),
                subtitle: Text(s.totpEnabled
                    ? 'On — connecting also needs the code from your authenticator app'
                    : 'Off — add an authenticator app for a second check on every connection'),
                trailing: FilledButton.tonal(
                  onPressed: () async {
                    final m = ScaffoldMessenger.of(context);
                    final changed = s.totpEnabled ? await disableTwoFactor(context, s) : await setupTwoFactor(context, s);
                    if (changed) {
                      m.showSnackBar(SnackBar(
                          content: Text(s.totpEnabled
                              ? 'Two-factor authentication is on.'
                              : 'Two-factor authentication is off.')));
                    }
                  },
                  child: Text(s.totpEnabled ? 'Turn off' : 'Set up'),
                ),
              ),
              if (kCanHost)
                SwitchListTile(
                  secondary: const Icon(Icons.settings_remote),
                  title: const Text('Allow remote control of this device'),
                  subtitle: Text(h.running
                      ? 'Listening on port $port${h.error != null ? ' — ${h.error}' : ''}'
                      : (h.error ?? 'Off')),
                  value: s.hostEnabled,
                  onChanged: (v) => app.setHostEnabled(v),
                )
              else
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('This device can control others'),
                  subtitle: Text('iOS does not allow apps to be remotely controlled, so this device works as a controller and file share only.'),
                ),
              if (app.hostWarning != null)
                ListTile(leading: const Icon(Icons.warning_amber, color: Colors.orange), title: Text(app.hostWarning!)),
            ]),
          ),
          if (kCanHost && (Platform.isAndroid || Platform.isMacOS))
            Card(
              child: Column(children: [
                ListTile(title: Text('Permissions', style: tt.titleMedium), trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: _refreshPerms)),
                if (Platform.isAndroid) ...[
                  _perm('Screen sharing', _capturing, () async {
                    await AndroidBridge.startCapture();
                    await _refreshPerms();
                  }, 'Start'),
                  _perm('Remote input (Accessibility service)', _a11y, AndroidBridge.openAccessibilitySettings, 'Enable'),
                  _perm('All files access (file sharing)', _files, AndroidBridge.requestAllFilesAccess, 'Allow'),
                ],
                if (Platform.isMacOS) ...[
                  _perm('Screen Recording', _macScreen, mac.macRequestScreenAccess, 'Request'),
                  _perm('Accessibility (remote input)', _macA11y, mac.macOpenAccessibilitySettings, 'Open settings'),
                ],
              ]),
            ),
          Card(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ListTile(title: Text('How to reach this device', style: tt.titleMedium)),
              for (final ip in app.localIps)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.lan_outlined),
                  title: SelectableText(kHasWan ? '$ip:$port' : ip),
                  subtitle: const Text('Local network'),
                  trailing: IconButton(icon: const Icon(Icons.copy), onPressed: () => Clipboard.setData(ClipboardData(text: kHasWan ? '$ip:$port' : ip))),
                ),
              if (kHasWan) ...[
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.public),
                  title: SelectableText(app.upnp.externalIp != null ? '${app.upnp.externalIp}:$port' : 'Public IP unknown'),
                  subtitle: Text(app.upnpBusy
                      ? 'Asking the router to open port $port (UPnP)…'
                      : app.upnp.error ?? (app.upnp.externalIp != null ? 'Router port forwarded automatically (UPnP). Use this on the other device.' : '')),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (app.upnp.externalIp != null)
                      IconButton(icon: const Icon(Icons.copy), onPressed: () => Clipboard.setData(ClipboardData(text: '${app.upnp.externalIp}:$port'))),
                    IconButton(icon: const Icon(Icons.refresh), onPressed: app.upnpBusy ? null : app.refreshUpnp),
                  ]),
                ),
                SwitchListTile(
                  title: const Text('Open the port on my router automatically (UPnP)'),
                  value: s.upnpEnabled,
                  onChanged: (v) async {
                    s.upnpEnabled = v;
                    await s.save();
                    if (v) await app.refreshUpnp();
                  },
                ),
              ],
            ]),
          ),
          if (h.sessions.isNotEmpty)
            Card(
              child: Column(children: [
                ListTile(
                  title: Text('Connected now', style: tt.titleMedium),
                  trailing: TextButton.icon(onPressed: h.disconnectAll, icon: const Icon(Icons.link_off), label: const Text('Disconnect all')),
                ),
                for (final x in h.sessions.values)
                  ListTile(leading: const Icon(Icons.screen_share), title: Text(x.peerName), subtitle: Text('${x.address} · ${x.peerOs}')),
              ]),
            ),
          Card(
            child: Column(children: [
              ListTile(title: Text('Files & drives', style: tt.titleMedium)),
              SwitchListTile(
                title: const Text('Share this device\'s storage with connected devices'),
                value: s.shareFiles,
                onChanged: (v) async {
                  s.shareFiles = v;
                  await s.save();
                },
              ),
              SwitchListTile(
                title: const Text('Show connected devices\' storage as drives'),
                subtitle: Text(Platform.isIOS
                    ? 'iOS: browse remote files from the session toolbar; downloads appear in Files → On My iPhone → Localview.'
                    : Platform.isWindows
                        ? 'Appears in File Explorer → This PC (uses the Windows WebClient service).'
                        : Platform.isMacOS
                            ? 'Appears in Finder → Locations.'
                            : Platform.isAndroid
                                ? 'Appears in the Files app sidebar.'
                                : 'Appears in the Files sidebar (GVfs).'),
                value: s.mountDrives,
                onChanged: (v) async {
                  s.mountDrives = v;
                  await s.save();
                },
              ),
              for (final d in app.mountedDrives.values) ListTile(dense: true, leading: const Icon(Icons.storage), title: Text(d)),
            ]),
          ),
          Card(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ListTile(title: Text('Appearance', style: tt.titleMedium)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'system', icon: Icon(Icons.brightness_auto), label: Text('System')),
                    ButtonSegment(value: 'light', icon: Icon(Icons.light_mode), label: Text('Light')),
                    ButtonSegment(value: 'dark', icon: Icon(Icons.dark_mode), label: Text('Dark')),
                    ButtonSegment(value: 'oled', icon: Icon(Icons.contrast), label: Text('OLED')),
                  ],
                  selected: {s.theme},
                  onSelectionChanged: (v) async {
                    s.theme = v.first;
                    await s.save();
                  },
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.animation),
                title: const Text('Animations'),
                subtitle: const Text('Switches, menus, dialogs, page transitions and touch ripples'),
                value: s.animations,
                onChanged: (v) async {
                  s.animations = v;
                  await s.save();
                },
              ),
              if (!Platform.isIOS)
                SwitchListTile(
                  secondary: const Icon(Icons.cloud_sync_outlined),
                  title: const Text('Keep running in the background'),
                  subtitle: Text(Platform.isAndroid
                      ? 'Closing Localview keeps your connections, and the drives they share, open (shown as a notification)'
                      : 'Closing the window keeps your connections and their drives open, and this computer reachable. '
                          'Reopen it from the ${Platform.isMacOS ? 'Dock' : 'tray icon'} or by starting Localview again'),
                  value: s.keepInBackground,
                  onChanged: (v) async {
                    s.keepInBackground = v;
                    await s.save();
                  },
                ),
            ]),
          ),
          Card(
            child: Column(children: [
              ListTile(title: Text('Streaming quality (when this device is controlled)', style: tt.titleMedium)),
              ListTile(
                title: const Text('Resolution'),
                trailing: DropdownButton<double>(
                  value: s.streamScale,
                  items: const [
                    DropdownMenuItem(value: 1.0, child: Text('100%')),
                    DropdownMenuItem(value: 0.75, child: Text('75%')),
                    DropdownMenuItem(value: 0.5, child: Text('50%')),
                  ],
                  onChanged: (v) async {
                    s.streamScale = v ?? 1.0;
                    await s.save();
                  },
                ),
              ),
              ListTile(
                title: const Text('Max frame rate'),
                trailing: DropdownButton<int>(
                  value: s.maxFps,
                  items: const [
                    DropdownMenuItem(value: 15, child: Text('15 fps')),
                    DropdownMenuItem(value: 30, child: Text('30 fps')),
                    DropdownMenuItem(value: 60, child: Text('60 fps')),
                  ],
                  onChanged: (v) async {
                    s.maxFps = v ?? 30;
                    await s.save();
                  },
                ),
              ),
            ]),
          ),
          const _UpdatesCard(),
          if (!Platform.isIOS)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.power_settings_new),
                label: const Text('Quit Localview'),
                onPressed: () => _quit(context, app),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('Localview $kModeLabel $kAppVersion · end-to-end encrypted (X25519 + ChaCha20-Poly1305)',
                textAlign: TextAlign.center, style: tt.bodySmall),
          ),
        ]);
      },
    );
  }
}

/// Bottom of "This device": check for and install a newer Localview.
class _UpdatesCard extends StatefulWidget {
  const _UpdatesCard();
  @override
  State<_UpdatesCard> createState() => _UpdatesCardState();
}

class _UpdatesCardState extends State<_UpdatesCard> {
  static UpdateInfo? _cached; // one automatic check per app start
  UpdateInfo? _info = _cached;
  bool _checking = false;
  double? _progress;
  String? _message;
  bool _restartReady = false;

  @override
  void initState() {
    super.initState();
    if (_cached == null) _check();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _message = null;
    });
    try {
      final u = await checkForUpdate();
      _cached = u;
      if (mounted) setState(() => _info = u);
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not check for updates: $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _update() async {
    final u = _info;
    if (u == null || u.assetUrl == null) return;
    setState(() {
      _progress = 0;
      _message = 'Downloading ${u.assetName}…';
    });
    try {
      final f = await downloadUpdate(u, (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) setState(() => _message = 'Installing…');
      final msg = await installUpdate(f);
      if (mounted) {
        setState(() {
          _message = msg ?? 'Follow the installer to finish the update.';
          _restartReady = msg != null && msg.startsWith('Updated');
        });
      }
    } catch (e) {
      if (mounted) setState(() => _message = 'Update failed: $e');
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final u = _info;
    final busy = _progress != null;
    String status;
    if (_checking) {
      status = 'Checking for updates…';
    } else if (u == null) {
      status = 'Version $kAppVersion';
    } else if (u.newer) {
      status = 'Version ${u.version} is available (you have $kAppVersion).';
    } else {
      status = 'You have the latest version ($kAppVersion).';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(u?.newer == true ? Icons.system_update : Icons.update),
            title: Text('Updates', style: tt.titleMedium),
            subtitle: Text(status),
          ),
          if (u != null && u.newer && u.notes.isNotEmpty && !_restartReady)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text("What's new in ${u.version}", style: tt.labelLarge),
                const SizedBox(height: 4),
                Text(u.notes, style: tt.bodySmall, maxLines: 8, overflow: TextOverflow.ellipsis),
              ]),
            ),
          if (busy) ...[progressBar(_progress), const SizedBox(height: 8)],
          if (_message != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_message!, style: tt.bodySmall)),
          Wrap(spacing: 10, runSpacing: 8, children: [
            if (_restartReady)
              FilledButton.icon(onPressed: restartApp, icon: const Icon(Icons.restart_alt), label: const Text('Restart now'))
            else if (u != null && u.newer && u.assetUrl != null && !Platform.isIOS)
              FilledButton.icon(
                onPressed: busy ? null : _update,
                icon: const Icon(Icons.download),
                label: Text('Update to ${u.version}'),
              ),
            if (u != null && u.newer && (u.assetUrl == null || Platform.isIOS))
              FilledButton.tonalIcon(
                onPressed: () => Clipboard.setData(ClipboardData(text: u.pageUrl)),
                icon: const Icon(Icons.copy),
                label: const Text('Copy download link'),
              ),
            OutlinedButton.icon(
              onPressed: _checking || busy ? null : _check,
              icon: const Icon(Icons.refresh),
              label: const Text('Check for updates'),
            ),
          ]),
          if (u != null && u.newer && Platform.isIOS)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('iOS apps can\'t update themselves: sideload the new .ipa from the release page.', style: tt.bodySmall),
            ),
        ]),
      ),
    );
  }
}

/// Quits Localview completely (instead of keeping it in the background), after confirming
/// when that ends connections or remote access.
Future<void> _quit(BuildContext context, AppController app) async {
  final n = app.clients.length;
  final hosting = app.store.hostEnabled && kCanHost;
  if (n > 0 || hosting) {
    final what = [
      if (n > 0) 'disconnects $n device${n == 1 ? '' : 's'} and their drives',
      if (hosting) 'this device can no longer be reached until you open Localview again',
    ].join('; ');
    final ok = await showDialog<bool>(
      animationStyle: dialogAnimation(),
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quit Localview?'),
        content: Text('Quitting $what.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Quit')),
        ],
      ),
    );
    if (ok != true) return;
  }
  await app.quit();
}
