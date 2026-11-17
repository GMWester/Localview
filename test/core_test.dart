import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/codec.dart';
import 'package:localview/src/crypto.dart';
import 'package:localview/src/protocol.dart';
import 'package:localview/src/storage.dart';

import 'dart:io';

void main() {
  test('session keys agree and frames authenticate', () async {
    final a = await EphemeralKeys.create(), b = await EphemeralKeys.create();
    final secret = await derivePasswordKey('hunter22', [1, 2, 3]);
    final nc = randomBytes(16), nh = randomBytes(16);
    final ka = await deriveSessionKeys(
      ecdh: await a.agree(b.publicKey),
      secret: secret,
      nonceClient: nc,
      nonceHost: nh,
    );
    final kb = await deriveSessionKeys(
      ecdh: await b.agree(a.publicKey),
      secret: secret,
      nonceClient: nc,
      nonceHost: nh,
    );
    final client = SecureChannel(sendKey: ka.c2h, recvKey: ka.h2c, isClient: true);
    final host = SecureChannel(sendKey: kb.h2c, recvKey: kb.c2h, isClient: false);
    for (var i = 0; i < 3; i++) {
      final ct = await client.seal([1, 2, 3, i]);
      expect(await host.open(ct), [1, 2, 3, i]);
    }
    final ct = await client.seal([9]);
    ct[0] ^= 1;
    expect(() => host.open(ct), throwsA(isA<DecryptError>()));

    final wrong = await deriveSessionKeys(
      ecdh: await b.agree(a.publicKey),
      secret: await derivePasswordKey('nope', [1, 2, 3]),
      nonceClient: nc,
      nonceHost: nh,
    );
    final host2 = SecureChannel(sendKey: wrong.h2c, recvKey: wrong.c2h, isClient: false);
    final c2 = SecureChannel(sendKey: ka.c2h, recvKey: ka.h2c, isClient: true);
    expect(() async => host2.open(await c2.seal([1])), throwsA(isA<DecryptError>()));
  });

  test('frame codec round trip with deltas and scaling', () {
    const w = 200, h = 130;
    final px = Uint8List(w * h * 4);
    for (var i = 0; i < px.length; i++) {
      px[i] = (i * 7) & 0xff;
    }
    final enc = FrameEncoder(), dec = FrameDecoder();
    dec.apply(enc.encode(RawFrame(w, h, w * 4, px, PixelFmt.bgra))!);
    for (var i = 0; i < px.length; i += 4) {
      expect(dec.fb![i], px[i]);
      expect(dec.fb![i + 2], px[i + 2]);
    }
    expect(enc.encode(RawFrame(w, h, w * 4, px, PixelFmt.bgra)), isNull);
    px[(100 * w + 150) * 4] = 1;
    final delta = enc.encode(RawFrame(w, h, w * 4, px, PixelFmt.bgra))!;
    expect(ByteData.sublistView(delta).getUint16(6), 1); // one rect
    dec.apply(delta);
    expect(dec.fb![(100 * w + 150) * 4], 1);
    final half = FrameEncoder().encode(RawFrame(w, h, w * 4, px, PixelFmt.bgra), scale: 0.5)!;
    final d2 = FrameDecoder()..apply(half);
    expect(d2.width, 100);
    expect(d2.height, 65);
  });

  test('password can be looked up on the device that set it', () async {
    final dir = await Directory.systemTemp.createTemp('lvstore');
    final a = await AppStore.load(dir: dir);
    await a.setPassword('my secret pw');
    final b = await AppStore.load(dir: dir);
    expect(b.password, 'my secret pw');
    expect(b.passwordVerifier, await derivePasswordKey('my secret pw', b.passwordSalt!));
  });
}
