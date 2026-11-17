import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/client.dart';
import 'package:localview/src/codec.dart';
import 'package:localview/src/crypto.dart';
import 'package:localview/src/host.dart';
import 'package:localview/src/protocol.dart';
import 'package:localview/src/storage.dart';
import 'package:localview/src/totp.dart';

void main() {
  testWidgets('extra windows: a session ticket connects without password or code; wrong / stale tickets are refused',
      (tester) async {
    HttpOverrides.global = null;
    await tester.runAsync(() async {
      final hostStore = AppStore.memory()..tcpPort = 0;
      await hostStore.setPassword('correct horse');
      final secret = newTotpSecret();
      hostStore.totpSecret = secret;
      final host = HostService(hostStore,
          externalCapture: () async => RawFrame(64, 64, 256, Uint8List(64 * 64 * 4), PixelFmt.rgba));
      await host.start();
      final client = AppStore.memory();
      ConnectParams params({String? pw, String? tid, Uint8List? tkey, String? myId}) => ConnectParams(
          host: '127.0.0.1',
          port: host.boundPort!,
          password: pw,
          ticketId: tid,
          ticketKey: tkey,
          myId: myId ?? client.deviceId,
          myName: 'PC',
          share: false);

      // Full login (password + authenticator code) issues a ticket.
      final code = await totpCode(secret, totpStep(DateTime.now()));
      final main = await ClientSession.connect(params(pw: 'correct horse'), askTotp: () async => code);
      expect(main.ticketId, isNotNull);
      expect(main.ticketKey, hasLength(32));

      // Two extra windows at once: no password, no code asked.
      var asked = 0;
      Future<String?> ask() async {
        asked++;
        return null;
      }

      final w1 = await ClientSession.connect(params(tid: main.ticketId, tkey: main.ticketKey), askTotp: ask);
      final w2 = await ClientSession.connect(params(tid: main.ticketId, tkey: main.ticketKey), askTotp: ask);
      expect(w1.connected && w2.connected, isTrue);
      expect(asked, 0);
      expect(w1.ticketId, main.ticketId); // windows keep using the same ticket

      // The ticket keeps working after the main window disconnects.
      await main.close();
      final w3 = await ClientSession.connect(params(tid: main.ticketId, tkey: main.ticketKey), askTotp: ask);
      expect(w3.connected, isTrue);

      // A wrong key, an unknown ticket or another device's ID are refused.
      await expectLater(ClientSession.connect(params(tid: main.ticketId, tkey: randomBytes(32)), askTotp: ask),
          throwsA(predicate((e) => '$e'.contains('access expired'))));
      await expectLater(ClientSession.connect(params(tid: 'nope', tkey: main.ticketKey), askTotp: ask),
          throwsA(predicate((e) => '$e'.contains('access expired'))));
      await expectLater(
          ClientSession.connect(params(tid: main.ticketId, tkey: main.ticketKey, myId: 'someone-else'), askTotp: ask),
          throwsA(predicate((e) => '$e'.contains('access expired'))));

      // Changing the password invalidates every ticket.
      await hostStore.setPassword('new password');
      await hostStore.save();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await expectLater(ClientSession.connect(params(tid: main.ticketId, tkey: main.ticketKey), askTotp: ask),
          throwsA(predicate((e) => '$e'.contains('access expired'))));
      expect(asked, 0);

      for (final w in [w1, w2, w3]) {
        await w.close();
      }
      await host.stop();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
