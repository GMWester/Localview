import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../client.dart';
import 'theme.dart';

/// Finds the adb program (PATH, then the usual Android SDK locations).
String? findAdb() {
  final exe = Platform.isWindows ? 'adb.exe' : 'adb';
  final env = Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
  final dirs = [
    ...?env['PATH']?.split(Platform.isWindows ? ';' : ':'),
    if (env['ANDROID_HOME'] != null) '${env['ANDROID_HOME']}/platform-tools',
    if (env['ANDROID_SDK_ROOT'] != null) '${env['ANDROID_SDK_ROOT']}/platform-tools',
    if (Platform.isWindows && env['LOCALAPPDATA'] != null) '${env['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools',
    if (Platform.isMacOS) '$home/Library/Android/sdk/platform-tools',
    if (Platform.isLinux) '$home/Android/Sdk/platform-tools',
    if (Platform.isMacOS) '/opt/homebrew/bin',
  ];
  for (final d in dirs) {
    if (d.isEmpty) continue;
    final f = File('$d${Platform.pathSeparator}$exe');
    if (f.existsSync()) return f.path;
  }
  return null;
}

/// ADB over Localview: forwards the device's adb ports to this computer and pairs / connects adb.
Future<void> showAdbDialog(BuildContext context, ClientSession s) => showDialog<void>(
      animationStyle: dialogAnimation(),
      context: context,
      builder: (_) => _AdbDialog(session: s),
    );

class _AdbDialog extends StatefulWidget {
  const _AdbDialog({required this.session});
  final ClientSession session;
  @override
  State<_AdbDialog> createState() => _AdbDialogState();
}

class _AdbDialogState extends State<_AdbDialog> {
  Map<String, dynamic>? _info;
  int? _connectLocal, _pairLocal;
  String? _output;
  bool _busy = false;
  final _code = TextEditingController();
  final String? _adb = Platform.isWindows || Platform.isLinux || Platform.isMacOS ? findAdb() : null;

  ClientSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    final info = await s.adbInfo();
    final connect = [...(info['connect'] as List? ?? const []).cast<int>(), if (info['legacy'] != null) info['legacy'] as int];
    final pairing = (info['pairing'] as List? ?? const []).cast<int>();
    final c = connect.isEmpty ? null : await s.forwardPort(connect.first);
    final p = pairing.isEmpty ? null : await s.forwardPort(pairing.first);
    if (!mounted) return;
    setState(() {
      _info = info;
      _connectLocal = c;
      _pairLocal = p;
      _busy = false;
    });
    // adb is here and the device is ready: connect right away.
    if (c != null && _adb != null && _output == null) await _run(['connect', '127.0.0.1:$c']);
  }

  Future<void> _run(List<String> args) async {
    final adb = _adb;
    if (adb == null) return;
    setState(() => _busy = true);
    String out;
    try {
      final r = await Process.run(adb, args).timeout(const Duration(seconds: 30));
      out = '${r.stdout}${r.stderr}'.trim();
    } catch (e) {
      out = '$e';
    }
    if (mounted) {
      setState(() {
        _output = 'adb ${args.join(' ')}\n$out';
        _busy = false;
      });
    }
  }

  Widget _command(String cmd) => Row(children: [
        Expanded(child: SelectableText(cmd, style: const TextStyle(fontFamily: 'monospace'))),
        IconButton(
          tooltip: 'Copy',
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () => Clipboard.setData(ClipboardData(text: cmd)),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final i = _info;
    final name = s.peerName;
    final List<Widget> body;
    if (i == null) {
      body = [Center(child: busyIndicator())];
    } else if (i['allowed'] != true) {
      body = [
        Text('$name does not allow ADB over Localview yet.'),
        const SizedBox(height: 8),
        Text('On $name: Localview → This device → turn on "ADB over Localview".'),
      ];
    } else {
      final sdk = i['sdk'] as int? ?? 0;
      body = [
        if (i['developerOptions'] != true)
          Text('On $name, turn on Developer options: Settings → About → tap "Build number" 7 times.'),
        if (_connectLocal == null && i['developerOptions'] == true)
          Text(sdk >= 30
              ? 'On $name: Settings → Developer options → turn on "Wireless debugging" (needs Wi-Fi on $name), then Refresh.'
              : '$name (Android ${sdk > 0 ? 'API $sdk' : ''}) has no wireless debugging. If "Network debugging" / ADB over network '
                  'exists in its Developer options, turn it on (port 5555), then Refresh.'),
        if (_pairLocal != null) ...[
          const SizedBox(height: 8),
          const Text('Pair this computer (first time only): enter the 6-digit code shown on the device.'),
          if (_adb != null)
            Row(children: [
              SizedBox(
                width: 140,
                child: TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Pairing code', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _busy ? null : () => _run(['pair', '127.0.0.1:$_pairLocal', _code.text.trim()]),
                child: const Text('Pair'),
              ),
            ])
          else
            _command('adb pair 127.0.0.1:$_pairLocal <code>'),
        ] else if (_connectLocal != null && sdk >= 30) ...[
          const SizedBox(height: 8),
          Text('First time from this computer? On $name: Wireless debugging → "Pair device with pairing code", then Refresh.'),
        ],
        if (_connectLocal != null) ...[
          const SizedBox(height: 12),
          Text('adb reaches $name at 127.0.0.1:$_connectLocal on this computer (through Localview, end-to-end encrypted):'),
          _command('adb connect 127.0.0.1:$_connectLocal'),
          if (_adb != null)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: _busy ? null : () => _run(['connect', '127.0.0.1:$_connectLocal']),
                child: const Text('Connect adb'),
              ),
            ),
        ],
        if (_adb == null && (Platform.isWindows || Platform.isLinux || Platform.isMacOS))
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('adb was not found on this computer: install Android SDK Platform-Tools, or run the commands above yourself.'),
          ),
        if (_output != null) ...[
          const SizedBox(height: 12),
          SelectableText(_output!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
        const SizedBox(height: 8),
        const Text('The ports stay open while this connection is open (also in the background).',
            style: TextStyle(fontSize: 12)),
      ];
    }
    return AlertDialog(
      title: Text('ADB · $name'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: body)),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : _refresh, child: const Text('Refresh')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
