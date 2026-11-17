import 'dart:io';

import 'package:flutter/foundation.dart';

import 'android.dart';

/// Mounts a peer's storage (served on a loopback WebDAV URL) as a drive in the
/// OS file manager.
class DriveMounter {
  /// Why the last mount failed (shown to the user), or null.
  String? lastError;

  final Map<String, String> _mounted = {}; // key -> OS handle (drive letter / url / volume)

  /// Returns a human-readable location, or null if mounting isn't supported.
  Future<String?> mount(String key, String name, String url, String volume) async {
    try {
      lastError = null;
      if (Platform.isWindows) return await _mountWindows(key, name, url);
      if (Platform.isMacOS) return await _mountMac(key, url, volume);
      if (Platform.isLinux) return await _mountLinux(key, url);
      if (Platform.isAndroid) {
        await AndroidBridge.addDrive(key, name, url);
        _mounted[key] = key;
        return 'Files app → $name';
      }
    } catch (e) {
      debugPrint('mount failed: $e');
    }
    return null;
  }

  Future<void> unmount(String key) async {
    final h = _mounted.remove(key);
    if (h == null) return;
    try {
      if (Platform.isWindows) {
        await Process.run('net', ['use', h, '/delete', '/y']);
      } else if (Platform.isMacOS) {
        await Process.run('diskutil', ['unmount', 'force', h]);
      } else if (Platform.isLinux) {
        await Process.run('gio', ['mount', '-u', h]);
      } else if (Platform.isAndroid) {
        await AndroidBridge.removeDrive(h);
      }
    } catch (e) {
      debugPrint('unmount failed: $e');
    }
  }

  Future<void> unmountAll() async {
    for (final k in _mounted.keys.toList()) {
      await unmount(k);
    }
  }

  Future<String?> _mountWindows(String key, String name, String url) async {
    // The WebClient service backs WebDAV drive mapping; it trigger-starts on demand.
    await Process.run('sc', ['start', 'WebClient']);
    final u = Uri.parse(url);
    // http://127.0.0.1:PORT/a/b/ and its UNC form \\127.0.0.1@PORT\a\b (some setups only accept one).
    final unc = '\\\\${u.host}@${u.port}\\${u.pathSegments.where((s) => s.isNotEmpty).join('\\')}';
    var out = '';
    RegExpMatch? m;
    for (final target in [url, unc]) {
      final r = await Process.run('net', ['use', '*', target, '/persistent:no']);
      out = '${r.stdout}${r.stderr}'.trim();
      m = RegExp(r'\b([D-Z]):').firstMatch(out);
      if (r.exitCode == 0 && m != null) break;
      m = null;
    }
    if (m == null) {
      debugPrint('net use failed: $out');
      lastError = out.isEmpty ? 'Windows could not map the drive.' : out;
      if (out.contains('67') || out.toLowerCase().contains('webclient')) {
        lastError = '$lastError\nCheck that the "WebClient" service is installed and not disabled (services.msc).';
      }
      return null;
    }
    final letter = '${m.group(1)}:';
    _mounted[key] = letter;
    // Give the drive a friendly label in Explorer.
    final regKey = '##${u.host}@${u.port}#${u.pathSegments.where((s) => s.isNotEmpty).join('#')}';
    await Process.run('reg', [
      'add',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\' + regKey,
      '/v',
      '_LabelFromReg',
      '/d',
      '$name (Localview)',
      '/f'
    ]);
    return '$letter drive';
  }

  Future<String?> _mountMac(String key, String url, String volume) async {
    final r = await Process.run('osascript', ['-e', 'mount volume "$url"']);
    if (r.exitCode != 0) {
      debugPrint('mount volume failed: ${r.stderr}');
      return null;
    }
    _mounted[key] = '/Volumes/$volume';
    return 'Finder → $volume';
  }

  Future<String?> _mountLinux(String key, String url) async {
    final dav = url.replaceFirst('http://', 'dav://');
    final r = await Process.run('gio', ['mount', dav]);
    if (r.exitCode != 0) {
      debugPrint('gio mount failed: ${r.stderr}');
      return null;
    }
    _mounted[key] = dav;
    return 'Files → $dav';
  }
}
