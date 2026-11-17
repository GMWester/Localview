import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/totp.dart';

void main() {
  // RFC 6238 appendix B, SHA-1 secret "12345678901234567890".
  final secret = Uint8List.fromList(utf8.encode('12345678901234567890'));

  test('RFC 6238 test vectors (8 digits)', () async {
    final vectors = {59: '94287082', 1111111109: '07081804', 1111111111: '14050471', 1234567890: '89005924', 2000000000: '69279037'};
    for (final e in vectors.entries) {
      expect(await totpCode(secret, e.key ~/ 30, digits: 8), e.value, reason: 'T=${e.key}');
    }
  });

  test('6-digit codes, drift window and base32 round trip', () async {
    final t = DateTime.fromMillisecondsSinceEpoch(1111111109 * 1000);
    expect(await totpCode(secret, totpStep(t)), '081804');
    expect(await totpVerify(secret, '081804', now: t), totpStep(t));
    expect(await totpVerify(secret, '081 804', now: t.add(const Duration(seconds: 30))), totpStep(t));
    expect(await totpVerify(secret, '081804', now: t.add(const Duration(seconds: 90))), isNull);
    expect(await totpVerify(secret, '000000', now: t), isNull);
    expect(base32Encode(secret), 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
    expect(base32Decode('gezd gnbv gy3t qojq gezd gnbv gy3t qojq'), secret);
    final s = newTotpSecret();
    expect(base32Decode(base32Encode(s)), s);
    expect(totpUri(s, 'Office PC'), startsWith('otpauth://totp/Localview%3AOffice%20PC?secret='));
  });
}
