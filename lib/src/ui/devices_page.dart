import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../config.dart';
import '../discovery.dart';
import '../storage.dart';
import 'connect.dart';
import 'home_page.dart';

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => kIsWan ? _WanDevices(app: app) : _LanDevices(app: app);
}

// ---------------------------------------------------------------- LAN

class _LanDevices extends StatefulWidget {
  const _LanDevices({required this.app});
  final AppController app;
  @override
  State<_LanDevices> createState() => _LanDevicesState();
}

class _LanDevicesState extends State<_LanDevices> {
  late final DiscoveryScanner scanner = DiscoveryScanner(widget.app.store.deviceId);

  @override
  void initState() {
    super.initState();
    scanner.start();
  }

  @override
  void dispose() {
    scanner.dispose();
    super.dispose();
  }

  Future<void> _open(LanDevice d) async {
    if (!d.hasPassword) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${d.name} has not set a password yet (This device → Password).')));
      return;
    }
    final pw = await askPassword(context, d.name);
    if (pw == null || pw.isEmpty || !mounted) return;
    await connectTo(context, widget.app, host: d.address, port: d.port, password: pw);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: scanner,
      builder: (context, _) {
        final list = scanner.list;
        return RefreshIndicator(
          onRefresh: scanner.scan,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text('Devices on this network running Localview LAN', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Select a device and enter the password that was set on it. All traffic is end-to-end encrypted.'),
            const SizedBox(height: 12),
            if (list.isEmpty)
              const Card(
                child: ListTile(
                  leading: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                  title: Text('Searching…'),
                  subtitle: Text('Make sure the other device has Localview LAN open and is on the same router.'),
                ),
              ),
            for (final d in list)
              Card(
                child: ListTile(
                  leading: Icon(osIcon(d.os), size: 32),
                  title: Text(d.name),
                  subtitle: Text('${d.address} · ${d.os}${d.hasPassword ? '' : ' · no password set'}'),
                  trailing: const Icon(Icons.lock_outline),
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
      listenable: app.store,
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
    final subtitle = [
      '${d.address}${d.port == kDefaultTcpPort ? '' : ':${d.port}'}',
      if (d.outgoing) 'you control it',
      if (d.allowIncoming) 'it can control this device',
    ].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(osIcon(d.os), size: 32),
      title: Text(d.name),
      subtitle: Text(subtitle),
      onTap: () => connectTo(context, app, host: d.address, port: d.port, paired: d),
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          switch (v) {
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
          const PopupMenuItem(value: 'edit', child: Text('Edit address')),
          CheckedPopupMenuItem(value: 'allow', checked: d.allowIncoming, child: const Text('Allow it to control this device')),
          const PopupMenuItem(value: 'remove', child: Text('Remove (deletes the key)')),
        ],
      ),
    );
  }
}
