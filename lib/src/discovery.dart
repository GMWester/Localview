import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'config.dart';

class LanDevice {
  LanDevice(this.id, this.name, this.os, this.address, this.port, this.hasPassword, this.lastSeen, {this.totp = false});
  final String id, name, os, address;
  final int port;
  final bool hasPassword;
  final bool totp;
  DateTime lastSeen;
}

/// Answers discovery queries so other Localview devices on the LAN can list this one.
class DiscoveryResponder {
  DiscoveryResponder(this.info);

  /// Returns the current announcement (or null to stay silent, e.g. hosting disabled).
  final Map<String, Object?>? Function() info;
  RawDatagramSocket? _sock;

  Future<void> start() async {
    try {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kDiscoveryPort, reuseAddress: true,
          reusePort: !Platform.isWindows && !Platform.isAndroid);
    } catch (e) {
      debugPrint('discovery responder bind failed: $e');
      return;
    }
    _sock!.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final d = _sock!.receive();
      if (d == null) return;
      try {
        final q = jsonDecode(utf8.decode(d.data)) as Map;
        if (q['lv'] != 1 || q['q'] != 1 || !kHasLan) return;
        final i = info();
        if (i == null) return;
        _sock!.send(utf8.encode(jsonEncode({'lv': 1, 'r': 1, 'mode': kModeName, ...i})), d.address, d.port);
      } catch (_) {}
    });
  }

  void stop() => _sock?.close();
}

/// Finds Localview hosts on the local network: broadcast query plus a unicast
/// sweep of the local /24 (needed on iOS and networks that drop broadcasts).
class DiscoveryScanner extends ChangeNotifier {
  DiscoveryScanner(this.myId);
  final String myId;
  final Map<String, LanDevice> devices = {};
  RawDatagramSocket? _sock;
  Timer? _timer;
  int _round = 0;

  List<LanDevice> get list => devices.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Future<void> start() async {
    _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _sock!.broadcastEnabled = true;
    _sock!.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final d = _sock!.receive();
      if (d == null) return;
      try {
        final r = jsonDecode(utf8.decode(d.data)) as Map;
        if (r['lv'] != 1 || r['r'] != 1) return;
        final id = r['id'] as String;
        if (id == myId) return;
        devices[id] = LanDevice(id, r['name'] as String, r['os'] as String? ?? '', d.address.address,
            r['port'] as int, r['pw'] == true, DateTime.now(), totp: r['totp'] == true);
        notifyListeners();
      } catch (_) {}
    });
    await scan();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => scan());
  }

  Future<void> scan() async {
    final s = _sock;
    if (s == null) return;
    final q = utf8.encode(jsonEncode({'lv': 1, 'q': 1, 'mode': kModeName}));
    final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
    final sweep = _round++ % 3 == 0;
    try {
      for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in ni.addresses) {
          if (a.isLoopback) continue;
          final p = a.rawAddress;
          targets.add(InternetAddress.fromRawAddress(Uint8ListHelper.of([p[0], p[1], p[2], 255])));
          if (sweep && (p[0] == 10 || (p[0] == 172 && p[1] >= 16 && p[1] < 32) || (p[0] == 192 && p[1] == 168))) {
            for (var i = 1; i < 255; i++) {
              if (i != p[3]) targets.add(InternetAddress.fromRawAddress(Uint8ListHelper.of([p[0], p[1], p[2], i])));
            }
          }
        }
      }
    } catch (_) {}
    for (final t in targets) {
      try {
        s.send(q, t, kDiscoveryPort);
      } catch (_) {}
    }
    final now = DateTime.now();
    final before = devices.length;
    devices.removeWhere((_, d) => now.difference(d.lastSeen) > const Duration(seconds: 12));
    if (devices.length != before) notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sock?.close();
    super.dispose();
  }
}

abstract final class Uint8ListHelper {
  static Uint8List of(List<int> l) => Uint8List.fromList(l);
}
