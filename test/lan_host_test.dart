import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/ui/adb_dialog.dart';

void main() {
  test('adb goes direct only to local-network addresses', () {
    for (final h in ['192.168.0.243', '10.1.2.3', '172.20.0.5', '169.254.3.4', 'fe80::1', 'fd12::5']) {
      expect(isLanHost(h), isTrue, reason: h);
    }
    for (final h in ['127.0.0.1', '::1', '8.8.8.8', '172.32.0.1', '2001:db8::1', 'example.com']) {
      expect(isLanHost(h), isFalse, reason: h);
    }
  });
}
