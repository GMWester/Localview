import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/client.dart';
import 'package:localview/src/codec.dart';
import 'package:localview/src/host.dart';
import 'package:localview/src/protocol.dart';
import 'package:localview/src/storage.dart';
import 'package:localview/src/totp.dart';

void main() {
  testWidgets('2FA: correct code connects, wrong/reused/cancelled are refused, applies to paired devices', (tester) async {
    HttpOverrides.global = null;
    await tester.runAsync(() async {
      final hostStore = AppStore.memory()..tcpPort = 0;
      await hostStore.setPassword('correct horse');
      final secret = newTotpSecret();
      hostStore.totpSecret = secret;
      final host = HostService(hostStore, externalCapture: () async =>
          RawFrame(64, 64, 256, Uint8List(64 * 64 * 4), PixelFmt.rgba));
      await host.start();
      final client = AppStore.memory();
      ConnectParams params({String? pw, Uint8List? key, bool pair = false}) => ConnectParams(
          host: '127.0.0.1', port: host.boundPort!, password: pw, pairKey: key, wantPair: pair,
          myId: client.deviceId, myName: 'Phone', share: false);
      Future<String> current() => totpCode(secret, totpStep(DateTime.now()));

      var asked = 0;
      await expectLater(
          ClientSession.connect(params(pw: 'correct horse'), askTotp: () async {
            asked++;
            return '000000';
          }),
          throwsA(predicate((e) => '$e'.contains('Wrong authenticator code'))));
      expect(asked, 1);

      await expectLater(ClientSession.connect(params(pw: 'correct horse'), askTotp: () async => null),
          throwsA(predicate((e) => '$e'.contains('cancelled'))));

      final code = await current();
      final s = await ClientSession.connect(params(pw: 'correct horse', pair: true), askTotp: () async => code);
      expect(s.connected, isTrue);
      final key = s.newPairKey!;
      await s.close();

      // The same code can't be used twice.
      await expectLater(ClientSession.connect(params(pw: 'correct horse'), askTotp: () async => code),
          throwsA(predicate((e) => '$e'.contains('already used'))));

      // Paired devices also need the code (next time step, as the current one is used).
      final next = await totpCode(secret, totpStep(DateTime.now()) + 1);
      final s2 = await ClientSession.connect(params(key: key), askTotp: () async => next);
      expect(s2.connected, isTrue);
      await s2.close();
      await host.stop();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
