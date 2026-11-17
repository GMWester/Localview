import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'config.dart';
import 'crypto.dart';

/// A device this device has been paired with (WAN mode).
/// [key] is the 256-bit pairing key generated during pairing and stored on both devices.
class PairedDevice {
  PairedDevice({
    required this.id,
    required this.name,
    required this.os,
    required this.address,
    required this.port,
    required this.key,
    required this.allowIncoming,
    required this.outgoing,
    this.lanAddress,
    this.lanPort,
  });

  final String id;
  String name;
  String os;
  String address;
  int port;
  final Uint8List key;

  /// May this peer control *this* device?
  bool allowIncoming;

  /// Did *this* device add the peer (so it is something we control)?
  bool outgoing;

  /// Last address seen on the local network (combined builds prefer it when the device is nearby).
  String? lanAddress;
  int? lanPort;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'os': os,
        'address': address,
        'port': port,
        'key': base64Encode(key),
        'allowIncoming': allowIncoming,
        'outgoing': outgoing,
        if (lanAddress != null) 'lanAddress': lanAddress,
        if (lanPort != null) 'lanPort': lanPort,
      };

  factory PairedDevice.fromJson(Map<String, dynamic> j) => PairedDevice(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Device',
        os: j['os'] as String? ?? '',
        address: j['address'] as String? ?? '',
        port: j['port'] as int? ?? kDefaultTcpPort,
        key: base64Decode(j['key'] as String),
        allowIncoming: j['allowIncoming'] as bool? ?? false,
        outgoing: j['outgoing'] as bool? ?? false,
        lanAddress: j['lanAddress'] as String?,
        lanPort: j['lanPort'] as int?,
      );
}

/// Persistent app state (stored as JSON with 0600 permissions where supported).
class AppStore extends ChangeNotifier {
  AppStore._(this._file);

  final File? _file;
  String deviceId = '';
  String deviceName = '';
  bool hostEnabled = true;

  /// PBKDF2(password, salt). The plain password is never stored.
  Uint8List? passwordSalt;
  Uint8List? passwordVerifier;

  /// The password itself, kept only on this device (owner-only file) so the
  /// user can look it up if they forget it. Never sent to other devices.
  String? password;

  int tcpPort = kDefaultTcpPort;
  bool upnpEnabled = true;
  double streamScale = 1.0;
  int maxFps = 30;

  /// Let connected devices browse/mount this device's storage.
  bool shareFiles = true;

  /// Mount connected devices' storage as drives in the OS file manager.
  bool mountDrives = true;

  /// Appearance: 'system', 'light', 'dark' or 'oled' (pure black for OLED screens).
  String theme = 'system';

  /// Root directory shared (null = whole filesystem / all drives on Windows).
  String? fsRoot;
  final List<PairedDevice> paired = [];

  bool get hasPassword => passwordVerifier != null;

  static Future<AppStore> load({Directory? dir}) async {
    Directory d;
    try {
      d = dir ?? await getApplicationSupportDirectory();
    } catch (_) {
      d = Directory.systemTemp;
    }
    await d.create(recursive: true);
    final f = File('${d.path}${Platform.pathSeparator}localview_$kModeName.json');
    final s = AppStore._(f);
    if (await f.exists()) {
      try {
        s._fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      } catch (e) {
        debugPrint('Localview: corrupt state file, starting fresh: $e');
      }
    }
    if (s.deviceId.isEmpty) {
      s.deviceId = _randomId();
    }
    if (s.deviceName.isEmpty) {
      s.deviceName = _defaultName();
    }
    await s.save();
    return s;
  }

  /// In-memory store (tests).
  static AppStore memory() {
    final s = AppStore._(null);
    s.deviceId = _randomId();
    s.deviceName = _defaultName();
    return s;
  }

  static String _randomId() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static String _defaultName() {
    try {
      final h = Platform.localHostname;
      if (h.isNotEmpty && h != 'localhost') return h;
    } catch (_) {}
    return 'My ${kOsName[0].toUpperCase()}${kOsName.substring(1)} device';
  }

  void _fromJson(Map<String, dynamic> j) {
    deviceId = j['deviceId'] as String? ?? '';
    deviceName = j['deviceName'] as String? ?? '';
    hostEnabled = j['hostEnabled'] as bool? ?? true;
    final salt = j['passwordSalt'] as String?;
    final ver = j['passwordVerifier'] as String?;
    if (salt != null && ver != null) {
      passwordSalt = base64Decode(salt);
      passwordVerifier = base64Decode(ver);
    }
    password = j['password'] as String?;
    tcpPort = j['tcpPort'] as int? ?? kDefaultTcpPort;
    upnpEnabled = j['upnpEnabled'] as bool? ?? true;
    streamScale = (j['streamScale'] as num?)?.toDouble() ?? 1.0;
    maxFps = j['maxFps'] as int? ?? 30;
    shareFiles = j['shareFiles'] as bool? ?? true;
    theme = j['theme'] as String? ?? 'system';
    mountDrives = j['mountDrives'] as bool? ?? true;
    paired
      ..clear()
      ..addAll(((j['paired'] as List?) ?? const [])
          .map((e) => PairedDevice.fromJson((e as Map).cast<String, dynamic>())));
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'hostEnabled': hostEnabled,
        if (passwordSalt != null) 'passwordSalt': base64Encode(passwordSalt!),
        if (passwordVerifier != null) 'passwordVerifier': base64Encode(passwordVerifier!),
        if (password != null) 'password': password,
        'tcpPort': tcpPort,
        'upnpEnabled': upnpEnabled,
        'streamScale': streamScale,
        'maxFps': maxFps,
        'shareFiles': shareFiles,
        'theme': theme,
        'mountDrives': mountDrives,
        'paired': paired.map((p) => p.toJson()).toList(),
      };

  Future<void> save() async {
    notifyListeners();
    final f = _file;
    if (f == null) return;
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(toJson()), flush: true);
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', tmp.path]);
      } catch (_) {}
    }
    await tmp.rename(f.path);
  }

  Future<void> setPassword(String password) async {
    final salt = randomBytes(16);
    passwordSalt = salt;
    passwordVerifier = await derivePasswordKey(password, salt);
    this.password = password;
    await save();
  }

  Future<void> clearPassword() async {
    passwordSalt = null;
    passwordVerifier = null;
    password = null;
    await save();
  }

  PairedDevice? findPaired(String id) {
    for (final p in paired) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> upsertPaired(PairedDevice d) async {
    paired.removeWhere((p) => p.id == d.id);
    paired.add(d);
    await save();
  }

  Future<void> removePaired(String id) async {
    paired.removeWhere((p) => p.id == id);
    await save();
  }
}
