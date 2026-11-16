import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// End-to-end encryption for Localview.
///
/// Handshake: both sides create an ephemeral X25519 key pair and exchange the
/// public keys plus 16-byte nonces. The session keys are
///   HKDF-SHA256(ikm = X25519(shared) || secret, salt = nonceC || nonceH)
/// where `secret` is either
///   * PBKDF2-SHA256(password, hostSalt, 120k iterations)  (LAN / first WAN pairing), or
///   * the 256-bit pairing key created when the device was added (WAN reconnects).
/// Every frame is sealed with ChaCha20-Poly1305 using a per-direction key and a
/// strictly increasing counter nonce, so replayed/reordered/tampered frames fail.
const int kPbkdf2Iterations = 120000;

final _rng = Random.secure();

Uint8List randomBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

Future<Uint8List> derivePasswordKey(String password, List<int> salt) async {
  final pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: kPbkdf2Iterations, bits: 256);
  final k = await pbkdf2.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
  return Uint8List.fromList(await k.extractBytes());
}

class EphemeralKeys {
  EphemeralKeys._(this._pair, this.publicKey);
  final SimpleKeyPair _pair;
  final Uint8List publicKey;

  static Future<EphemeralKeys> create() async {
    final pair = await X25519().newKeyPair();
    final pub = await pair.extractPublicKey();
    return EphemeralKeys._(pair, Uint8List.fromList(pub.bytes));
  }

  Future<Uint8List> agree(List<int> remotePublic) async {
    if (remotePublic.length != 32) throw const FormatException('bad public key');
    final shared = await X25519().sharedSecretKey(
      keyPair: _pair,
      remotePublicKey: SimplePublicKey(remotePublic, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await shared.extractBytes());
  }
}

/// Derives the two directional 256-bit keys.
Future<({SecretKey c2h, SecretKey h2c})> deriveSessionKeys({
  required List<int> ecdh,
  required List<int> secret,
  required List<int> nonceClient,
  required List<int> nonceHost,
}) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 64);
  final out = await hkdf.deriveKey(
    secretKey: SecretKey([...ecdh, ...secret]),
    nonce: [...nonceClient, ...nonceHost],
    info: utf8.encode('localview-session-v1'),
  );
  final b = await out.extractBytes();
  return (c2h: SecretKey(b.sublist(0, 32)), h2c: SecretKey(b.sublist(32, 64)));
}

class DecryptError implements Exception {
  const DecryptError();
  @override
  String toString() => 'DecryptError: authentication failed';
}

/// Seals/opens frames for one direction pair.
class SecureChannel {
  SecureChannel({required this._sendKey, required this._recvKey, required bool isClient})
      : _sendPrefix = isClient ? 0x43324821 : 0x48324321,
        _recvPrefix = isClient ? 0x48324321 : 0x43324821;

  static final Cipher _aes = Chacha20.poly1305Aead();
  final SecretKey _sendKey;
  final SecretKey _recvKey;
  final int _sendPrefix;
  final int _recvPrefix;
  int _sendCounter = 0;
  int _recvCounter = 0;

  static List<int> _nonce(int prefix, int counter) {
    final n = ByteData(12);
    n.setUint32(0, prefix);
    n.setUint64(4, counter);
    return n.buffer.asUint8List();
  }

  /// Returns ciphertext || 16-byte tag. Nonces are implicit (counters).
  Future<Uint8List> seal(List<int> plain) async {
    final nonce = _nonce(_sendPrefix, _sendCounter++);
    final box = await _aes.encrypt(plain, secretKey: _sendKey, nonce: nonce);
    final out = Uint8List(box.cipherText.length + 16);
    out.setRange(0, box.cipherText.length, box.cipherText);
    out.setRange(box.cipherText.length, out.length, box.mac.bytes);
    return out;
  }

  Future<Uint8List> open(Uint8List sealed) async {
    if (sealed.length < 16) throw const DecryptError();
    final nonce = _nonce(_recvPrefix, _recvCounter);
    final ct = Uint8List.sublistView(sealed, 0, sealed.length - 16);
    final mac = Mac(Uint8List.sublistView(sealed, sealed.length - 16));
    try {
      final plain = await _aes.decrypt(SecretBox(ct, nonce: nonce, mac: mac), secretKey: _recvKey);
      _recvCounter++;
      return plain is Uint8List ? plain : Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw const DecryptError();
    }
  }
}

/// Short human-readable fingerprint of a key (shown in the UI so users can compare).
Future<String> fingerprint(List<int> key) async {
  final h = await Sha256().hash(key);
  final hex = h.bytes.take(6).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 4)}-${hex.substring(4, 8)}-${hex.substring(8, 12)}'.toUpperCase();
}
