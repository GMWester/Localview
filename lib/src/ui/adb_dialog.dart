import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:material_ui/material_ui.dart';

import '../client.dart';
import 'theme.dart';

String get _adbExe => Platform.isWindows ? 'adb.exe' : 'adb';

/// Where "Install adb" puts Android SDK Platform-Tools.
Future<Directory> _ownToolsDir() async => Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}platform-tools');

/// adb installed by Localview itself, else [findAdb].
Future<String?> findAdbAnywhere() async {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return null;
  try {
    final f = File('${(await _ownToolsDir()).path}${Platform.pathSeparator}$_adbExe');
    if (f.existsSync()) return f.path;
  } catch (_) {}
  return findAdb();
}

/// Downloads Google's Android SDK Platform-Tools (adb) into Localview's own folder. Returns adb's path.
Future<String> installAdb() async {
  final os = Platform.isWindows ? 'windows' : (Platform.isMacOS ? 'darwin' : 'linux');
  final url = Uri.parse('https://dl.google.com/android/repository/platform-tools-latest-$os.zip');
  final client = HttpClient();
  try {
    final req = await client.getUrl(url);
    final res = await req.close();
    if (res.statusCode != 200) throw HttpException('download failed (HTTP ${res.statusCode})', uri: url);
    final bytes = <int>[];
    await for (final c in res) {
      bytes.addAll(c);
    }
    final dir = await _ownToolsDir();
    await extractPlatformTools(bytes, dir.parent.path);
    final adb = '${dir.path}${Platform.pathSeparator}$_adbExe';
    if (!Platform.isWindows) await Process.run('chmod', ['+x', adb]);
    if (!File(adb).existsSync()) throw const FileSystemException('adb is missing from the download');
    return adb;
  } finally {
    client.close();
  }
}

/// True if [host] is an address on the local network, where adb can reach the device's wireless
/// debugging port directly (faster and more reliable than through the encrypted session).
bool isLanHost(String host) {
  final a = InternetAddress.tryParse(host);
  if (a == null || a.isLoopback) return false;
  if (a.type == InternetAddressType.IPv4) {
    final b = a.rawAddress;
    return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254);
  }
  return a.isLinkLocal || (a.rawAddress[0] & 0xFE) == 0xFC; // fe80::/10, fc00::/7
}

Future<String> _adbOut(String adb, List<String> args, {Duration timeout = const Duration(seconds: 15)}) async {
  try {
    final r = await Process.run(adb, args).timeout(timeout);
    return '${r.stdout}${r.stderr}'.trim();
  } catch (e) {
    return '$e';
  }
}

/// Connects adb to [target] (ip:port); retries once after dropping a stale ("offline") entry.
Future<bool> adbConnect(String adb, String target) async {
  var out = await _adbOut(adb, ['connect', target]);
  if (out.contains('connected to') && !out.contains('failed')) {
    final state = await _adbOut(adb, ['-s', target, 'get-state'], timeout: const Duration(seconds: 5));
    if (state.trim() == 'device') return true;
  }
  await _adbOut(adb, ['disconnect', target]);
  out = await _adbOut(adb, ['connect', target]);
  return out.contains('connected to') && !out.contains('failed');
}

/// Localview Pro: connects adb to the controlled Android device (directly over the local network
/// when possible, otherwise through Localview) and starts the real mouse & keyboard helper.
/// Returns null when there was nothing to do (no adb, not a Pro device, already running, not
/// paired yet...), else a short message.
Future<String?> autoStartPro(ClientSession s) async {
  final adb = await findAdbAnywhere();
  if (adb == null || !s.peerAdb) return null;
  final info = await s.adbInfo();
  final cmd = info['proCommand'] as String?;
  if (cmd == null || info['proRunning'] == true) return null;
  final ports = [...(info['connect'] as List? ?? const []).cast<int>(), if (info['legacy'] != null) info['legacy'] as int];
  if (ports.isEmpty) return null; // wireless debugging is off
  final targets = <String>[
    if (isLanHost(s.params.host)) '${s.params.host}:${ports.first}',
  ];
  final local = await s.forwardPort(ports.first);
  if (local != null) targets.add('127.0.0.1:$local');
  for (final t in targets) {
    if (!await adbConnect(adb, t)) continue;
    await _adbOut(adb, ['-s', t, 'shell', cmd]);
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if ((await s.adbInfo())['proRunning'] == true) return 'Real mouse & keyboard started on ${s.peerName}.';
    }
    return null;
  }
  return null; // not paired with this computer yet: the ADB dialog does that once
}

/// Stops every adb server on this computer (`adb kill-server`, then any adb process left over,
/// e.g. from another adb copy). Returns a short report.
Future<String> stopAdbServers() async {
  final adb = await findAdbAnywhere();
  var asked = false;
  if (adb != null) {
    try {
      await Process.run(adb, ['kill-server']).timeout(const Duration(seconds: 10));
      asked = true;
    } catch (_) {}
  }
  var killed = false;
  try {
    final r = Platform.isWindows
        ? await Process.run('taskkill', ['/F', '/IM', 'adb.exe'])
        : await Process.run('pkill', ['-x', 'adb']);
    killed = r.exitCode == 0;
  } catch (_) {}
  if (killed) return 'Stopped the adb servers that were still running.';
  if (asked) return 'adb server stopped.';
  return 'No adb server was running.';
}

/// Unpacks a Platform-Tools zip (which holds platform-tools/...) into [root].
Future<void> extractPlatformTools(List<int> zip, String root) async {
  for (final f in ZipDecoder().decodeBytes(zip)) {
    if (!f.isFile || f.name.split('/').contains('..')) continue;
    final out = File('$root${Platform.pathSeparator}${f.name.replaceAll('/', Platform.pathSeparator)}');
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(f.content);
    if (!Platform.isWindows && (f.mode & 0x49) != 0) await Process.run('chmod', ['+x', out.path]);
  }
}

/// Finds the adb program (PATH, then the usual Android SDK locations).
String? findAdb() {
  final exe = _adbExe;
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
  String? _adb = Platform.isWindows || Platform.isLinux || Platform.isMacOS ? findAdb() : null;
  bool _installing = false;
  bool _late = false;
  int? _connectPort, _pairPort; // the device's own adb ports

  /// Same network: adb talks to the device directly (faster, and works when the tunnel doesn't).
  bool get _lan => isLanHost(s.params.host);
  String? get _target => _lan && _connectPort != null
      ? '${s.params.host}:$_connectPort'
      : (_connectLocal != null ? '127.0.0.1:$_connectLocal' : null);
  String? get _pairTarget => _lan && _pairPort != null
      ? '${s.params.host}:$_pairPort'
      : (_pairLocal != null ? '127.0.0.1:$_pairLocal' : null);

  ClientSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _install() async {
    setState(() => _installing = true);
    try {
      _adb = await installAdb();
      _output = null;
    } catch (e) {
      _output = 'Could not install adb: $e';
    }
    if (!mounted) return;
    setState(() => _installing = false);
    await _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    _adb ??= await findAdbAnywhere();
    final info = await s.adbInfo();
    if (info['allowed'] == null && _info != null && _info!['allowed'] == true) {
      // A late answer: keep what we knew (ports, buttons) and just say so.
      if (mounted) {
        setState(() {
          _late = true;
          _busy = false;
        });
      }
      return;
    }
    _late = false;
    final connect = [...(info['connect'] as List? ?? const []).cast<int>(), if (info['legacy'] != null) info['legacy'] as int];
    final pairing = (info['pairing'] as List? ?? const []).cast<int>();
    final c = connect.isEmpty ? null : await s.forwardPort(connect.first);
    final p = pairing.isEmpty ? null : await s.forwardPort(pairing.first);
    if (!mounted) return;
    setState(() {
      _info = info;
      _connectLocal = c;
      _pairLocal = p;
      _connectPort = connect.isEmpty ? null : connect.first;
      _pairPort = pairing.isEmpty ? null : pairing.first;
      _busy = false;
    });
    // adb is here and the device is ready: connect right away.
    final t = _target;
    if (t != null && _adb != null && _output == null) await _run(['connect', t]);
  }

  /// Starts the helper, then shows its log (read through adb, so it works even while the
  /// device answers slowly) and refreshes the status.
  Future<void> _startPro(String command, String? log) async {
    final dev = _target!;
    final adb = _adb;
    if (adb != null) await adbConnect(adb, dev);
    await _run(['-s', dev, 'shell', command]);
    final started = _output ?? '';
    await Future<void>.delayed(const Duration(seconds: 2));
    if (log != null) {
      await _run(['-s', dev, 'shell', 'cat $log; echo; ps -A 2>/dev/null | grep -c app_process']);
      if (mounted) setState(() => _output = '$started\n\nHelper log:\n${_output ?? ''}');
    }
    if (mounted) await _refresh();
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
    } else if (i['allowed'] == null) {
      // No answer (slow network or device): not the same as "not allowed".
      body = [Text('$name did not answer in time. Press Refresh to ask again.')];
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
        if (_target == null && i['developerOptions'] == true)
          Text(sdk >= 30
              ? 'On $name: Settings → Developer options → turn on "Wireless debugging" (needs Wi-Fi on $name), then Refresh.'
              : '$name (Android ${sdk > 0 ? 'API $sdk' : ''}) has no wireless debugging. If "Network debugging" / ADB over network '
                  'exists in its Developer options, turn it on (port 5555), then Refresh.'),
        if (_pairTarget != null) ...[
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
                onPressed: _busy ? null : () => _run(['pair', _pairTarget!, _code.text.trim()]),
                child: const Text('Pair'),
              ),
            ])
          else
            _command('adb pair $_pairTarget <code>'),
        ] else if (_target != null && sdk >= 30) ...[
          const SizedBox(height: 8),
          Text('First time from this computer? On $name: Wireless debugging → "Pair device with pairing code", then Refresh.'),
        ],
        if (_target != null) ...[
          const SizedBox(height: 12),
          Text(_lan
              ? 'adb reaches $name directly on your local network at $_target:'
              : 'adb reaches $name at $_target on this computer (through Localview, end-to-end encrypted):'),
          _command('adb connect $_target'),
          if (_adb != null)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: _busy ? null : () => _run(['connect', _target!]),
                child: const Text('Connect adb'),
              ),
            ),
        ],
        if (i['proCommand'] != null) ...[
          const Divider(height: 24),
          Text('Real mouse & keyboard (Localview Pro): ${i['proRunning'] == true ? 'running' : 'not running'}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (i['proError'] != null) ...[
            const SizedBox(height: 4),
            Text('${i['proError']}', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (i['proRunning'] != true) ...[
            const SizedBox(height: 4),
            Text('Starts a small helper on $name that sends real mouse and keyboard events (hover, right-click, '
                'wheel, shortcuts). Start it again after $name restarts.'),
            const SizedBox(height: 8),
            if (_adb != null && _target != null)
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _startPro(i['proCommand'] as String, i['proLog'] as String?),
                child: const Text('Start real mouse & keyboard'),
              )
            else
              _command('adb -s ${_target ?? '<ip:port>'} shell "${i['proCommand']}"'),
            const SizedBox(height: 8),
            Text('If that says "device offline": connect adb to $name directly over Wi-Fi (Wireless debugging shows '
                'its IP address & port: adb pair <ip:pairing port> <code>, then adb connect <ip:port>) and run:',
                style: const TextStyle(fontSize: 12)),
            _command('adb -s <ip:port> shell "${i['proCommand']}"'),
          ],
        ],
        if (_adb == null && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) ...[
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('adb is not on this computer yet. Localview can download it (Google\'s Android SDK Platform-Tools, '
                'about 7 MB) into its own folder; the buttons for pairing, connecting and real mouse & keyboard then appear here.'),
          ),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.icon(
              onPressed: _installing ? null : _install,
              icon: _installing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download),
              label: Text(_installing ? 'Installing adb…' : 'Install adb'),
            ),
          ]),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('By installing you accept the Android SDK Platform-Tools license (developer.android.com/tools/releases/platform-tools).',
                style: TextStyle(fontSize: 12)),
          ),
        ],
        const SizedBox(height: 8),
        const Text('The ports stay open while this connection is open (also in the background).',
            style: TextStyle(fontSize: 12)),
      ];
    }
    body.addAll([
      if (_late && i != null && i['allowed'] == true)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text('$name answered too slowly just now; this is what it said before. Press Refresh to ask again.',
              style: const TextStyle(fontSize: 12)),
        ),
      if (_output != null) ...[
        const SizedBox(height: 12),
        SelectableText(_output!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      ],
    ]);
    return AlertDialog(
      title: Text('ADB · $name'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: body)),
      ),
      actions: [
        if (_adb != null)
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    final msg = await stopAdbServers();
                    if (mounted) setState(() => _output = msg);
                  },
            child: const Text('Stop adb'),
          ),
        TextButton(onPressed: _busy ? null : _refresh, child: const Text('Refresh')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
