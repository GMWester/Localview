import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../client.dart';
import '../viewer_window.dart';
import 'remote_page.dart';
import 'theme.dart';

/// Home of an extra viewer window: connects with the session ticket it was opened with
/// and shows that device (and monitor). Closing the remote view closes the window.
class ViewerHome extends StatefulWidget {
  const ViewerHome({super.key, required this.app, required this.launch});
  final AppController app;
  final ViewerLaunch launch;

  @override
  State<ViewerHome> createState() => _ViewerHomeState();
}

class _ViewerHomeState extends State<ViewerHome> {
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  Future<void> _connect() async {
    setState(() => _error = null);
    final s = widget.app.store;
    final l = widget.launch;
    ClientSession session;
    try {
      session = await ClientSession.connect(ConnectParams(
        host: l.host,
        port: l.port,
        ticketId: l.ticketId,
        ticketKey: l.ticketKey,
        expectedId: l.deviceId,
        monitor: l.monitor,
        myId: s.deviceId,
        myName: s.deviceName,
        share: false, // files and drives stay with the main window
        mount: false,
        scale: s.streamScale,
        fps: s.maxFps,
      ));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RemotePage(app: widget.app, session: session)));
    await closeViewerWindow();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.launch.title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _error == null
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  busyIndicator(),
                  const SizedBox(height: 16),
                  Text('Connecting to ${widget.launch.title}…'),
                ])
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.error_outline, size: 40),
                  const SizedBox(height: 12),
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  Wrap(spacing: 12, children: [
                    FilledButton(onPressed: _connect, child: const Text('Try again')),
                    OutlinedButton(onPressed: closeViewerWindow, child: const Text('Close window')),
                  ]),
                ]),
        ),
      ),
    );
  }
}
