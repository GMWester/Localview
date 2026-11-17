// PC VR (SteamVR -> standalone headset).
//
// Host (Windows, Linux x64 / SteamOS): registers the bundled Localview SteamVR
// driver, writes the session (per-session 256-bit key + the headset's display
// description) for the driver, (re)starts SteamVR and opens the UDP port.
// On Linux it also installs the compositor capture layer (see vr/linux/README.md),
// so SteamVR games - native and Windows games through Proton - stream to the headset.
// Headset (Android XR / Meta Quest build): launches the native OpenXR activity,
// relays its display description to the PC and hands it the key/port.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../crypto.dart';
import '../protocol.dart';
import '../upnp.dart';

const int kVrUdpPort = 47920;

// ------------------------------------------------------------------ host side

String get _exeDir => File(Platform.resolvedExecutable).parent.path;

String? _driverDir() {
  if (Platform.isWindows) {
    final dir = '$_exeDir\\vr\\localview';
    return File('$dir\\driver.vrdrivermanifest').existsSync() ? dir : null;
  }
  if (Platform.isLinux && Abi.current() == Abi.linuxX64) {
    final dir = '$_exeDir/vr/localview';
    return File('$dir/bin/linux64/driver_localview.so').existsSync() ? dir : null;
  }
  return null;
}

/// True when this PC can stream SteamVR (Windows, or Linux x64 / SteamOS, with the bundled driver).
bool get pcvrHostSupported => _driverDir() != null;

String? _steamVrRuntimeWindows() {
  final local = Platform.environment['LOCALAPPDATA'];
  if (local == null) return null;
  final f = File('$local\\openvr\\openvrpaths.vrpath');
  if (!f.existsSync()) return null;
  try {
    final j = jsonDecode(f.readAsStringSync()) as Map;
    final rt = (j['runtime'] as List?)?.cast<String>() ?? const [];
    for (final r in rt) {
      if (File('$r\\bin\\win64\\vrstartup.exe').existsSync()) return r;
    }
  } catch (_) {}
  return null;
}

String get _home => Platform.environment['HOME'] ?? '';
File get _linuxVrPaths => File('$_home/.config/openvr/openvrpaths.vrpath');

String? _steamVrRuntimeLinux() {
  final candidates = <String>[];
  try {
    final j = jsonDecode(_linuxVrPaths.readAsStringSync()) as Map;
    candidates.addAll((j['runtime'] as List?)?.cast<String>() ?? const []);
  } catch (_) {}
  candidates.addAll([
    '$_home/.steam/steam/steamapps/common/SteamVR',
    '$_home/.local/share/Steam/steamapps/common/SteamVR',
    '$_home/.steam/debian-installation/steamapps/common/SteamVR',
  ]);
  for (final r in candidates) {
    if (File('$r/bin/linux64/vrserver').existsSync()) return r;
  }
  return null;
}

String? _which(String name, [List<String> extra = const []]) {
  for (final d in [...extra, ...(Platform.environment['PATH'] ?? '').split(':'), '/usr/bin', '/usr/local/bin']) {
    if (d.isEmpty) continue;
    final f = File('$d/$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

/// Same search as the driver (vr/driver/src/linux/encoder_linux.cpp).
bool _hasFfmpeg() =>
    _which('ffmpeg', ['$_home/.local/share/localview/ffmpeg', '$_home/.local/bin']) != null;

Future<void> _copyDir(Directory from, Directory to) async {
  await to.create(recursive: true);
  await for (final e in from.list(recursive: false, followLinks: true)) {
    final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (e is Directory) {
      await _copyDir(e, Directory('${to.path}/$name'));
    } else if (e is File) {
      final dest = File('${to.path}/$name');
      // Replace instead of overwriting in place: SteamVR may still have the old library mapped.
      if (dest.existsSync()) await dest.delete();
      await e.copy(dest.path);
    }
  }
}

Future<void> _chmod(String mode, String path) async {
  await Process.run('chmod', [mode, path]);
}

/// Linux: copies the driver + capture layer to a stable place (the app itself may be a
/// temporary AppImage mount), registers the driver with SteamVR and wraps its compositor.
Future<String> _installLinux(String runtime) async {
  final src = '$_exeDir/vr';
  final dest = '$_home/.local/share/localview/vr';
  await _copyDir(Directory('$src/localview'), Directory('$dest/localview'));
  for (final f in Directory('$dest/localview/bin/linux64').listSync().whereType<File>()) {
    await _chmod('755', f.path);
  }
  final layerLib = '$dest/localview/bin/linux64/liblocalview_vk_capture.so';
  final manifest = File('$src/linux/layer/localview_capture.json.in').readAsStringSync()
      .replaceAll('@LIBRARY_PATH@', layerLib);
  await Directory('$dest/layer').create(recursive: true);
  await File('$dest/layer/localview_capture.json').writeAsString(manifest);

  // Register the driver (same file vrpathreg edits).
  Map<String, dynamic> paths = {};
  try {
    paths = (jsonDecode(_linuxVrPaths.readAsStringSync()) as Map).cast<String, dynamic>();
  } catch (_) {}
  final drivers = ((paths['external_drivers'] as List?) ?? []).cast<Object?>().whereType<String>().toList();
  final driverDir = '$dest/localview';
  if (!drivers.contains(driverDir)) {
    drivers.removeWhere((d) => d.endsWith('/localview/vr/localview') || d.endsWith('/vr/localview'));
    drivers.add(driverDir);
    paths['external_drivers'] = drivers;
    paths['runtime'] ??= [runtime];
    paths['version'] ??= 1;
    paths['jsonid'] ??= 'vrpathreg';
    await _linuxVrPaths.parent.create(recursive: true);
    await _linuxVrPaths.writeAsString(const JsonEncoder.withIndent('\t').convert(paths));
  }

  // Wrap SteamVR's compositor so the capture layer is loaded while Localview streams.
  final bin = '$runtime/bin/linux64';
  final comp = File('$bin/vrcompositor');
  final real = File('$bin/vrcompositor.real');
  final wrapper = File('$src/linux/vrcompositor-wrapper.sh').readAsStringSync().replaceAll('@LV_DIR@', dest);
  final current = comp.existsSync() ? comp.readAsBytesSync() : <int>[];
  final isOurs = current.length < 8192 && utf8.decode(current, allowMalformed: true).contains('Localview PC VR');
  if (!isOurs) {
    if (comp.existsSync()) {
      // First install, or SteamVR updated its compositor: keep the new original.
      if (real.existsSync()) await real.delete();
      await comp.rename(real.path);
    }
    if (!real.existsSync()) throw 'SteamVR\'s compositor was not found in $bin. Verify SteamVR\'s files in Steam.';
  }
  await File(comp.path).writeAsString(wrapper);
  await _chmod('755', comp.path);
  return driverDir;
}

Future<void> _restartSteamVrLinux() async {
  for (final p in ['vrmonitor', 'vrdashboard', 'vrcompositor', 'vrcompositor.real', 'vrserver', 'vrwebhelper', 'vrstartup']) {
    await Process.run('pkill', ['-x', p.length > 15 ? p.substring(0, 15) : p]);
  }
  await Future<void>.delayed(const Duration(seconds: 2));
  const uri = 'steam://rungameid/250820'; // SteamVR
  final steam = _which('steam');
  if (steam != null) {
    await Process.start(steam, [uri], mode: ProcessStartMode.detached);
  } else if (_which('flatpak') != null) {
    await Process.start('flatpak', ['run', 'com.valvesoftware.Steam', uri], mode: ProcessStartMode.detached);
  } else {
    await Process.start('xdg-open', [uri], mode: ProcessStartMode.detached);
  }
}

Future<void> _setLinuxActive(bool active) async {
  final f = File('$_home/.config/localview/vr_active');
  try {
    if (active) {
      await f.parent.create(recursive: true);
      await f.writeAsString('${DateTime.now().toIso8601String()}\n');
    } else if (f.existsSync()) {
      await f.delete();
    }
  } catch (_) {}
}

class PcvrHost {
  PcvrHost({required this.send, this.upnp});
  final void Function(Uint8List) send;
  final Upnp? upnp;

  Future<void> handle(Uint8List m) async {
    if (m[0] == Msg.vrStop) {
      if (Platform.isLinux) await _setLinuxActive(false);
      return;
    }
    if (m[0] != Msg.vrStart) return;
    try {
      final j = jsonBody(m);
      final driver = _driverDir();
      if (driver == null) {
        throw 'PC VR needs the Windows, Linux (x64) or SteamOS version of Localview on the PC (the SteamVR driver is missing).';
      }
      final linux = Platform.isLinux;
      final runtime = linux ? _steamVrRuntimeLinux() : _steamVrRuntimeWindows();
      if (runtime == null) throw 'SteamVR is not installed on the PC. Install Steam and SteamVR, then try again.';
      if (linux && !_hasFfmpeg()) {
        throw 'PC VR on Linux needs ffmpeg on the PC to encode the video. Install it with your package manager '
            '(e.g. "sudo apt install ffmpeg", "sudo dnf install ffmpeg-free", "sudo pacman -S ffmpeg"). '
            'On SteamOS, put a static ffmpeg build in ~/.local/share/localview/ffmpeg/ffmpeg. Then try again.';
      }

      if (linux) {
        await _installLinux(runtime);
      } else {
        final reg = await Process.run('$runtime\\bin\\win64\\vrpathreg.exe', ['adddriver', driver]);
        if (reg.exitCode != 0) debugPrint('vrpathreg: ${reg.stdout} ${reg.stderr}');
      }

      final key = randomBytes(32);
      final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      List<num> nums(String k, int n) => ((j[k] as List?) ?? const []).cast<num>().take(n).toList();
      String join(List<num> l) => l.map((v) => v.toString()).join(' ');
      final lines = [
        'id=${DateTime.now().microsecondsSinceEpoch}',
        'key=$hex',
        'port=$kVrUdpPort',
        'eye_width=${j['eyeWidth']}',
        'eye_height=${j['eyeHeight']}',
        'refresh=${j['refresh']}',
        'bitrate=${j['bitrate'] ?? 150}',
        'controller_pitch=${j['controllerPitch'] ?? 0}',
        'name=${(j['name'] as String? ?? 'Headset').replaceAll(RegExp(r'[\r\n=]'), ' ')}',
        'fov_l=${join(nums('fovL', 4))}',
        'fov_r=${join(nums('fovR', 4))}',
        'eye_l=${join(nums('eyeL', 7))}',
        'eye_r=${join(nums('eyeR', 7))}',
      ];
      if (linux) {
        final dir = Directory('$_home/.config/localview');
        await dir.create(recursive: true);
        final f = File('${dir.path}/vr_session.txt');
        await f.writeAsString('');
        await _chmod('600', f.path); // holds the session key
        await f.writeAsString(lines.join('\n'));
        await _setLinuxActive(true);
      } else {
        final dir = Directory('${Platform.environment['LOCALAPPDATA']}\\Localview');
        await dir.create(recursive: true);
        await File('${dir.path}\\vr_session.txt').writeAsString(lines.join('\r\n'));
      }

      if (upnp != null) unawaited(upnp!.mapPort(kVrUdpPort, protocol: 'UDP'));

      // The headset resolution is fixed when SteamVR starts: restart it with the new session.
      if (linux) {
        await _restartSteamVrLinux();
      } else {
        for (final p in ['vrmonitor.exe', 'vrdashboard.exe', 'vrcompositor.exe', 'vrserver.exe']) {
          await Process.run('taskkill', ['/F', '/IM', p]);
        }
        await Future<void>.delayed(const Duration(seconds: 2));
        await Process.start('$runtime\\bin\\win64\\vrstartup.exe', const [], mode: ProcessStartMode.detached);
      }
      send(jsonMsg(Msg.vrReady, {'port': kVrUdpPort, 'key': hex}));
    } catch (e) {
      send(jsonMsg(Msg.vrError, {'error': '$e'}));
    }
  }
}

// ------------------------------------------------------------------ headset side

const MethodChannel _android = MethodChannel('localview/android');

class PcvrClient {
  PcvrClient({required this.host, required this.send, this.bitrateMbps = 150});
  final String host;
  final void Function(Uint8List) send;
  final int bitrateMbps;
  final _events = StreamController<String>.broadcast();

  /// Status/error messages for the UI.
  Stream<String> get events => _events.stream;
  bool active = false;

  static Future<bool> available() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _android.invokeMethod<bool>('vr.available') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> start() async {
    active = true;
    _android.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'vr.displayInfo':
          final info = (jsonDecode(call.arguments as String) as Map).cast<String, dynamic>();
          info['bitrate'] = bitrateMbps;
          _events.add('Starting SteamVR on the PC…');
          send(jsonMsg(Msg.vrStart, info));
        case 'vr.ended':
          stop();
        case 'vr.error':
          _events.add('${call.arguments}');
          stop();
      }
      return null;
    });
    await _android.invokeMethod('vr.start');
  }

  Future<void> handle(Uint8List m) async {
    switch (m[0]) {
      case Msg.vrReady:
        final j = jsonBody(m);
        await _android.invokeMethod('vr.connect', {'host': host, 'port': j['port'], 'key': j['key']});
        _events.add('Streaming SteamVR. Hold the left menu button for 3 s to leave.');
      case Msg.vrError:
        _events.add('${jsonBody(m)['error']}');
    }
  }

  void stop() {
    if (!active) return;
    active = false;
    send(Uint8List.fromList([Msg.vrStop]));
    _events.add('PC VR ended.');
  }
}
