// PC VR (SteamVR -> standalone headset).
//
// Host (Windows): registers the bundled Localview SteamVR driver, writes the
// session (per-session 256-bit key + the headset's display description) for
// the driver, (re)starts SteamVR and opens the UDP port.
// Headset (Android XR / Meta Quest build): launches the native OpenXR activity,
// relays its display description to the PC and hands it the key/port.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../crypto.dart';
import '../protocol.dart';
import '../upnp.dart';

const int kVrUdpPort = 47920;

// ------------------------------------------------------------------ host side

String? _driverDir() {
  if (!Platform.isWindows) return null;
  final dir = '${File(Platform.resolvedExecutable).parent.path}\\vr\\localview';
  return File('$dir\\driver.vrdrivermanifest').existsSync() ? dir : null;
}

/// True when this PC can stream SteamVR (Windows + bundled driver).
bool get pcvrHostSupported => _driverDir() != null;

String? _steamVrRuntime() {
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

class PcvrHost {
  PcvrHost({required this.send, this.upnp});
  final void Function(Uint8List) send;
  final Upnp? upnp;

  Future<void> handle(Uint8List m) async {
    if (m[0] == Msg.vrStop) return;
    if (m[0] != Msg.vrStart) return;
    try {
      final j = jsonBody(m);
      final driver = _driverDir();
      if (driver == null) throw 'PC VR needs the Windows version of Localview (the SteamVR driver is missing).';
      final runtime = _steamVrRuntime();
      if (runtime == null) throw 'SteamVR is not installed on the PC. Install Steam and SteamVR, then try again.';

      final reg = await Process.run('$runtime\\bin\\win64\\vrpathreg.exe', ['adddriver', driver]);
      if (reg.exitCode != 0) debugPrint('vrpathreg: ${reg.stdout} ${reg.stderr}');

      final key = randomBytes(32);
      final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      List<num> nums(String k, int n) => ((j[k] as List?) ?? const []).cast<num>().take(n).toList();
      String join(List<num> l) => l.map((v) => v.toString()).join(' ');
      final dir = Directory('${Platform.environment['LOCALAPPDATA']}\\Localview');
      await dir.create(recursive: true);
      await File('${dir.path}\\vr_session.txt').writeAsString([
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
      ].join('\r\n'));

      if (upnp != null) unawaited(upnp!.mapPort(kVrUdpPort, protocol: 'UDP'));

      // The headset resolution is fixed when SteamVR starts: restart it with the new session.
      for (final p in ['vrmonitor.exe', 'vrdashboard.exe', 'vrcompositor.exe', 'vrserver.exe']) {
        await Process.run('taskkill', ['/F', '/IM', p]);
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      await Process.start('$runtime\\bin\\win64\\vrstartup.exe', const [], mode: ProcessStartMode.detached);
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
