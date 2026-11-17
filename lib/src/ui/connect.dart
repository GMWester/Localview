import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../client.dart';
import '../config.dart';
import '../storage.dart';
import '../viewer_window.dart';
import 'remote_page.dart';
import 'two_factor.dart';
import 'theme.dart';

/// Connects, stores a new pairing if one was created, and opens the remote view.
Future<ClientSession?> connectTo(
  BuildContext context,
  AppController app, {
  required String host,
  required int port,
  String? password,
  PairedDevice? paired,
  bool pair = false,
  bool open = true,
  bool viaLan = false,
  bool newWindow = false,
}) async {
  final s = app.store;
  final key = 'client-${DateTime.now().microsecondsSinceEpoch}';
  final params = ConnectParams(
    host: host,
    port: port,
    password: password,
    pairKey: paired?.key,
    expectedId: paired?.id,
    wantPair: pair,
    myId: s.deviceId,
    myName: s.deviceName,
    share: s.shareFiles && !newWindow,
    fsRoot: s.fsRoot,
    mount: s.mountDrives && !newWindow,
    scale: s.streamScale,
    fps: s.maxFps,
  );
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  showDialog<void>(
    animationStyle: dialogAnimation(),
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: Row(children: [busyIndicator(), const SizedBox(width: 20), const Expanded(child: Text('Connecting securely…'))]),
    ),
  );
  ClientSession? session;
  String? err;
  try {
    session = await ClientSession.connect(params,
        onMount: (url, volume) async {
          final where = await app.mountDrive(key, volume, url, volume);
          final name = session?.peerName ?? volume;
          if (where != null) {
            messenger.showSnackBar(SnackBar(content: Text("$name's storage: $where")));
          } else if (app.store.mountDrives && app.drives.lastError != null) {
            messenger.showSnackBar(SnackBar(
                duration: const Duration(seconds: 10),
                content: Text("Couldn't show $name's storage as a drive: ${app.drives.lastError}")));
          }
        },
        onUnmount: () => app.unmountDrive(key),
        askTotp: () async => context.mounted ? askTotpCode(context, paired?.name ?? host) : null);
  } catch (e) {
    err = e.toString().replaceFirst('Exception: ', '');
  }
  nav.pop();
  if (session == null) {
    messenger.showSnackBar(SnackBar(content: Text(err ?? 'Connection failed.')));
    return null;
  }
  // From the LAN, remember the router-reported public IP as the "anywhere" address.
  final remoteAddress = (viaLan && kHasWan && session.peerPublicIp != null) ? session.peerPublicIp! : host;
  if (session.newPairKey != null) {
    final existing = s.findPaired(session.peerId);
    await s.upsertPaired(PairedDevice(
      id: session.peerId,
      name: session.peerName,
      os: session.peerOs,
      address: remoteAddress,
      port: port,
      key: session.newPairKey!,
      allowIncoming: existing?.allowIncoming ?? false,
      outgoing: true,
      lanAddress: viaLan ? host : existing?.lanAddress,
      lanPort: viaLan ? port : existing?.lanPort,
    ));
  } else if (paired != null) {
    paired
      ..name = session.peerName
      ..os = session.peerOs;
    if (viaLan) {
      paired
        ..lanAddress = host
        ..lanPort = port;
      if (session.peerPublicIp != null) paired.address = session.peerPublicIp!;
    }
    await s.save();
  }
  app.trackClient(session);
  if (newWindow) {
    // Logged in here (password / key / authenticator code); the new window uses the session ticket.
    final ok = session.ticketId != null &&
        await openViewerWindow(ViewerLaunch(
          host: host,
          port: port,
          ticketId: session.ticketId!,
          ticketKey: session.ticketKey!,
          deviceName: session.peerName,
          deviceId: session.peerId,
        ));
    await session.close();
    if (!ok) messenger.showSnackBar(const SnackBar(content: Text('Could not open a new window.')));
    return null;
  }
  if (open && context.mounted) {
    await nav.push(MaterialPageRoute<void>(builder: (_) => RemotePage(app: app, session: session!)));
  }
  return session;
}

Future<String?> askPassword(BuildContext context, String deviceName) {
  final c = TextEditingController();
  return showDialog<String>(
    animationStyle: dialogAnimation(),
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Connect to $deviceName'),
      content: TextField(
        controller: c,
        autofocus: true,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'Device password', border: OutlineInputBorder()),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Connect')),
      ],
    ),
  );
}

/// Parses "host", "host:port", "[v6]:port".
(String, int) parseAddress(String input) {
  final t = input.trim();
  final v6 = RegExp(r'^\[([^\]]+)\](?::(\d+))?$').firstMatch(t);
  if (v6 != null) return (v6.group(1)!, int.tryParse(v6.group(2) ?? '') ?? kDefaultTcpPort);
  final parts = t.split(':');
  if (parts.length == 2) return (parts[0], int.tryParse(parts[1]) ?? kDefaultTcpPort);
  return (t, kDefaultTcpPort);
}
