import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/discovery.dart';

void main() {
  test('a known device is asked directly every round, so it stays listed without broadcasts', () async {
    // Fake phone on loopback that answers only the direct (unicast) questions it receives.
    // Its own free port: other tests running at the same time listen on the real discovery port.
    final phone = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    var asked = 0;
    phone.listen((e) {
      final d = phone.receive();
      if (d == null) return;
      asked++;
      phone.send(utf8.encode(jsonEncode({'lv': 1, 'r': 1, 'id': 'phone', 'name': 'Phone', 'os': 'android', 'port': 1, 'pw': true})),
          d.address, d.port);
    });
    final s = DiscoveryScanner('pc', port: phone.port);
    await s.start();
    final old = DateTime.now().subtract(const Duration(seconds: 15));
    s.devices['phone'] = LanDevice('phone', 'Phone', 'android', '127.0.0.1', 1, true, old);
    await s.scan();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(asked, greaterThan(0));
    expect(s.devices['phone']!.lastSeen.isAfter(old), isTrue);
    // Not answering for longer than the expiry removes it.
    s.devices['phone'] = LanDevice('phone', 'Phone', 'android', '10.255.255.1', 1, true,
        DateTime.now().subtract(kDiscoveryExpiry + const Duration(seconds: 1)));
    phone.close();
    await s.scan();
    expect(s.devices.containsKey('phone'), isFalse);
    s.dispose();
  });
}
