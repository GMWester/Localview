import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../config.dart';
import '../discovery.dart';
import '../storage.dart';
import 'connect.dart';
import 'home_page.dart';
import 'theme.dart';
import '../viewer_window.dart';

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    if (!kIsCombined) return kHasWan ? _WanDevices(app: app) : _LanDevices(app: app);
    return DefaultTabController(
      length: 2,
      child: Column(children: [
        const TabBar(tabs: [
          Tab(icon: Icon(Icons.wifi), text: 'Nearby (LAN)'),
          Tab(icon: Icon(Icons.public), text: 'My devices (anywhere)'),
        ]),
        Expanded(child: TabBarView(children: [_LanDevices(app: app), _WanDevices(app: app)])),
      ]),
    );
  }
}

// ---------------------------------------------------------------- LAN

class _LanDevices extends StatefulWidget {
  const _LanDevices({required this.app});
  final AppController app;
  @override
  State<_LanDevices> createState() => _LanDevicesState();
}

class _LanDevicesState extends State<_LanDevices> {
  DiscoveryScanner get scanner => widget.app.scanner!;

  Future<void> _open(LanDevice d, {bool newWindow = false}) async {
    final paired = widget.app.store.findPaired(d.id);
    if (kIsCombined && paired != null) {
      // Already in "My devices": the stored pairing key is enough.
      await connectTo(context, widget.app,
          host: d.address, port: d.port, paired: paired, viaLan: true, newWindow: newWindow);
      return;
    }
    if (!d.hasPassword) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${d.name} has not set a password yet (This device → Password).')));
      return;
    }
    final pw = await askPassword(context, d.name);
    if (pw == null || pw.isEmpty || !mounted) return;
    // Combined builds also pair, so the device is reachable from anywhere afterwards.
    await connectTo(context, widget.app,
        host: d.address, port: d.port, password: pw, pair: kIsCombined, viaLan: true, newWindow: newWindow);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([scanner, widget.app.store]),
      builder: (context, _) {
        final list = scanner.list;
        return RefreshIndicator(
          onRefresh: scanner.scan,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text(kIsCombined ? 'Devices on this network running Localview' : 'Devices on this network running Localview LAN', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(kIsCombined
                ? 'Select a device and enter its password. It is then also added to My devices, so you can reach it from anywhere without the password.'
                : 'Select a device and enter the password that was set on it. All traffic is end-to-end encrypted.'),
            const SizedBox(height: 12),
            if (list.isEmpty)
              Card(
                child: ListTile(
                  leading: SizedBox(width: 24, height: 24, child: busyIndicator(strokeWidth: 2, size: 20)),
                  title: const Text('Searching…'),
                  subtitle: Text('Make sure the other device has Localview ${kIsCombined ? '(LAN or LAN + WAN)' : 'LAN'} open and is on the same router.'),
                ),
              ),
            for (final d in list)
              Card(
                child: ListTile(
                  leading: Icon(osIcon(d.os), size: 32),
                  title: Text(d.name),
                  subtitle: Text('${d.address} · ${d.os}${d.hasPassword ? '' : ' · no password set'}'
                      '${kIsCombined && widget.app.store.findPaired(d.id) != null ? ' · in My devices' : ''}'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (d.totp)
                      const Tooltip(message: 'Two-factor authentication', child: Icon(Icons.verified_user_outlined)),
                    const SizedBox(width: 8),
                    Icon(kIsCombined && widget.app.store.findPaired(d.id) != null ? Icons.key : Icons.lock_outline),
                    if (canOpenViewerWindows && !widget.app.isTv)
                      IconButton(
                        tooltip: 'Open in a new window',
                        icon: const Icon(Icons.open_in_new),
                        onPressed: () => _open(d, newWindow: true),
                      ),
                  ]),
                  onTap: () => _open(d),
                ),
              ),
          ]),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- WAN

class _WanDevices extends StatelessWidget {
  const _WanDevices({required this.app});
  final AppController app;

  Future<void> _add(BuildContext context) async {
    final addr = TextEditingController();
    final pw = TextEditingController();
    final ok = await showDialog<bool>(
      animationStyle: dialogAnimation(),
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a device'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: addr,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: 'IP address', hintText: '203.0.113.7 or host:$kDefaultTcpPort', border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pw,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password set on that device', border: OutlineInputBorder()),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: 8),
            const Text('A new encryption key is generated and saved on both devices. After this you won\'t need the password again.',
                style: TextStyle(fontSize: 12)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true || addr.text.trim().isEmpty || !context.mounted) return;
    final (host, port) = parseAddress(addr.text);
    final s = await connectTo(context, app, host: host, port: port, password: pw.text, pair: true, open: false);
    if (s != null) {
      await s.close();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${s.peerName} added.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app.store, if (app.scanner != null) app.scanner!]),
      builder: (context, _) {
        final devices = app.store.paired;
        return Scaffold(
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _add(context),
            icon: const Icon(Icons.add),
            label: const Text('Add device'),
          ),
          body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('My devices', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    IconButton.filledTonal(onPressed: () => _add(context), icon: const Icon(Icons.add), tooltip: 'Add device'),
                  ]),
                  const SizedBox(height: 8),
                  if (devices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text('No devices yet. Press + and enter the other device\'s IP address and password.'),
                    ),
                  for (final d in devices) _PairedTile(app: app, d: d),
                ]),
              ),
            ),
          ]),
        );
      },
    );
  }
}

class _PairedTile extends StatelessWidget {
  const _PairedTile({required this.app, required this.d});
  final AppController app;
  final PairedDevice d;

  Future<void> _edit(BuildContext context) async {
    final c = TextEditingController(text: d.port == kDefaultTcpPort ? d.address : '${d.address}:${d.port}');
    final v = await showDialog<String>(
      animationStyle: dialogAnimation(),
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Address of ${d.name}'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (v == null || v.trim().isEmpty) return;
    final (h, p) = parseAddress(v);
    d
      ..address = h
      ..port = p;
    await app.store.save();
  }

  @override
  Widget build(BuildContext context) {
    final nearby = app.scanner?.devices.containsKey(d.id) ?? false;
    final subtitle = [
      if (nearby) 'nearby (LAN)',
      '${d.address}${d.port == kDefaultTcpPort ? '' : ':${d.port}'}',
      if (d.outgoing) 'you control it',
      if (d.allowIncoming) 'it can control this device',
    ].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(osIcon(d.os), size: 32),
      title: Text(d.name),
      subtitle: Text(subtitle),
      onTap: () {
        final near = app.scanner?.devices[d.id];
        if (near != null) {
          connectTo(context, app, host: near.address, port: near.port, paired: d, viaLan: true);
        } else {
          connectTo(context, app, host: d.address, port: d.port, paired: d);
        }
      },
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          switch (v) {
            case 'window':
              final near = app.scanner?.devices[d.id];
              await connectTo(context, app,
                  host: near?.address ?? d.address,
                  port: near?.port ?? d.port,
                  paired: d,
                  viaLan: near != null,
                  newWindow: true);
            case 'edit':
              await _edit(context);
            case 'allow':
              d.allowIncoming = !d.allowIncoming;
              await app.store.save();
            case 'remove':
              await app.store.removePaired(d.id);
          }
        },
        itemBuilder: (_) => [
          if (canOpenViewerWindows && !app.isTv) const PopupMenuItem(value: 'window', child: Text('Open in a new window')),
          const PopupMenuItem(value: 'edit', child: Text('Edit address')),
          CheckedPopupMenuItem(value: 'allow', checked: d.allowIncoming, child: const Text('Allow it to control this device')),
          const PopupMenuItem(value: 'remove', child: Text('Remove (deletes the key)')),
        ],
      ),
    );
  }
}
