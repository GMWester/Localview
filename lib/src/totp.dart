// Time-based one-time passwords (RFC 6238 / RFC 4226) for authenticator apps
// (Google Authenticator, Microsoft Authenticator, Authy, 1Password, …):
// HMAC-SHA1, 6 digits, 30-second steps.
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto.dart';

const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

String base32Encode(List<int> data) {
  final out = StringBuffer();
  var buffer = 0, bits = 0;
  for (final b in data) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out.write(_alphabet[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
  }
  if (bits > 0) out.write(_alphabet[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

Uint8List base32Decode(String s) {
  final clean = s.toUpperCase().replaceAll(RegExp(r'[\s=-]'), '');
  final out = <int>[];
  var buffer = 0, bits = 0;
  for (final ch in clean.split('')) {
    final v = _alphabet.indexOf(ch);
    if (v < 0) throw const FormatException('invalid base32');
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      out.add((buffer >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Uint8List.fromList(out);
}

/// 160-bit secret, the size authenticator apps expect.
Uint8List newTotpSecret() => randomBytes(20);

/// Secret formatted for typing: groups of 4 characters.
String formatSecret(Uint8List secret) {
  final s = base32Encode(secret);
  return [for (var i = 0; i < s.length; i += 4) s.substring(i, i + 4 > s.length ? s.length : i + 4)].join(' ');
}

/// The otpauth:// URI that authenticator apps read from the QR code.
String totpUri(Uint8List secret, String account) {
  final label = Uri.encodeComponent('Localview:$account');
  return 'otpauth://totp/$label?secret=${base32Encode(secret)}&issuer=Localview&algorithm=SHA1&digits=6&period=30';
}

int totpStep(DateTime t) => t.millisecondsSinceEpoch ~/ 1000 ~/ 30;

Future<String> totpCode(Uint8List secret, int step, {int digits = 6}) async {
  final msg = ByteData(8)..setUint64(0, step);
  final mac = await Hmac.sha1().calculateMac(msg.buffer.asUint8List(), secretKey: SecretKey(secret));
  final h = mac.bytes;
  final off = h[h.length - 1] & 0x0f;
  final bin = ((h[off] & 0x7f) << 24) | (h[off + 1] << 16) | (h[off + 2] << 8) | h[off + 3];
  var mod = 1;
  for (var i = 0; i < digits; i++) {
    mod *= 10;
  }
  return (bin % mod).toString().padLeft(digits, '0');
}

/// Returns the matching time step (±1 step for clock drift), or null.
Future<int?> totpVerify(Uint8List secret, String code, {DateTime? now}) async {
  final c = code.replaceAll(RegExp(r'\s'), '');
  if (!RegExp(r'^\d{6}$').hasMatch(c)) return null;
  final step = totpStep(now ?? DateTime.now());
  for (final s in [step, step - 1, step + 1]) {
    if (await totpCode(secret, s) == c) return s;
  }
  return null;
}
