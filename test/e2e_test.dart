import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/client.dart';
import 'package:localview/src/codec.dart';
import 'package:localview/src/host.dart';
import 'package:localview/src/platform/platform.dart';
import 'package:localview/src/protocol.dart';
import 'package:localview/src/storage.dart';

class _Rec implements InputInjector {
  final events = <InputEvent>[];
  @override
  void inject(InputEvent e) => events.add(e);
}

void main() {
  testWidgets('host and client: password, pairing, video, input, files, drive bridge', (tester) async {
    HttpOverrides.global = null;
    await tester.runAsync(() async {
      final shared = await Directory.systemTemp.createTemp('lvshare');
      File('${shared.path}/hello.txt').writeAsStringSync('hello from host');
      final hostStore = AppStore.memory()
        ..tcpPort = 0
        ..fsRoot = shared.path;
      await hostStore.setPassword('correct horse');
      var tick = 0;
      final rec = _Rec();
      final host = HostService(hostStore, injector: rec, externalCapture: () async {
        const w = 320, h = 200;
        final px = Uint8List(w * h * 4)..fillRange(0, w * h * 4, (tick++ * 40) & 0xff);
        return RawFrame(w, h, w * 4, px, PixelFmt.rgba);
      });
      String? hostMountUrl;
      host.onMount = (sid, name, url, vol) async => hostMountUrl = url;
      await host.start();
      expect(host.boundPort, isNotNull);
      final port = host.boundPort!;

      final clientStore = AppStore.memory();
      final clientShare = await Directory.systemTemp.createTemp('lvclient');
      File('${clientShare.path}/client.txt').writeAsStringSync('from client');
      ConnectParams params({String? pw, Uint8List? key, bool pair = false}) => ConnectParams(
          host: '127.0.0.1', port: port, password: pw, pairKey: key, wantPair: pair,
          myId: clientStore.deviceId, myName: 'Test client', fsRoot: clientShare.path);

      // Wrong password is rejected.
      await expectLater(ClientSession.connect(params(pw: 'wrong')), throwsA(predicate((e) => '$e'.contains('Wrong password'))));

      // Correct password + pairing.
      String? clientMountUrl;
      final s = await ClientSession.connect(params(pw: 'correct horse', pair: true),
          onMount: (url, vol) async => clientMountUrl = url);
      expect(s.connected, isTrue);
      expect(s.newPairKey, isNotNull);
      expect(s.newPairKey!.length, 32);

      // Video arrives.
      for (var i = 0; i < 100 && s.image.value == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(s.image.value, isNotNull);
      expect(s.image.value!.width, 320);

      // Input arrives at the injector.
      s.send(pointerMoveMsg(0.25, 0.75));
      s.send(pointerButtonMsg(Btn.left, true));
      s.send(keyMsg(0x00070004, true));
      s.send(textMsg(Msg.text, 'héllo'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(rec.events.whereType<PointerMove>().first.x, closeTo(0.25, 1e-6));
      expect(rec.events.whereType<PointerButton>().first.down, isTrue);
      expect(rec.events.whereType<KeyInput>().first.hid, 0x00070004);
      expect(rec.events.whereType<TextEntry>().first.text, 'héllo');

      // Host stored the pairing (both devices hold the key).
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final hp = hostStore.findPaired(clientStore.deviceId);
      expect(hp, isNotNull);
      expect(hp!.key, s.newPairKey);
      expect(hp.allowIncoming, isTrue);

      // In-app file browsing.
      final list = await s.files.list('/');
      expect(list.map((e) => e.name), contains('hello.txt'));
      expect(utf8.decode(await s.files.read('/hello.txt', 0, 100)), 'hello from host');

      // Drive bridge (WebDAV) on the client exposes the host's storage.
      expect(clientMountUrl, isNotNull);
      final http = HttpClient();
      final pf = await http.openUrl('PROPFIND', Uri.parse(clientMountUrl!));
      pf.headers.set('Depth', '1');
      final pfr = await pf.close();
      final xml = await pfr.transform(utf8.decoder).join();
      expect(pfr.statusCode, 207);
      expect(xml, contains('hello.txt'));
      final put = await http.putUrl(Uri.parse('${clientMountUrl}new%20file.bin'));
      put.add(List<int>.generate(3 * 1024 * 1024 + 17, (i) => i & 0xff));
      expect((await put.close()).statusCode, 201);
      expect(File('${shared.path}/new file.bin').lengthSync(), 3 * 1024 * 1024 + 17);
      final get = await http.getUrl(Uri.parse('${clientMountUrl}hello.txt'));
      get.headers.set('Range', 'bytes=6-9');
      final gr = await get.close();
      expect(gr.statusCode, 206);
      expect(await gr.transform(utf8.decoder).join(), 'from');
      final mk = await http.openUrl('MKCOL', Uri.parse('${clientMountUrl}dir'));
      expect((await mk.close()).statusCode, 201);
      final mv = await http.openUrl('MOVE', Uri.parse('${clientMountUrl}new%20file.bin'));
      mv.headers.set('Destination', '${clientMountUrl}dir/moved.bin');
      expect((await mv.close()).statusCode, 201);
      expect(File('${shared.path}/dir/moved.bin').existsSync(), isTrue);

      // The host side mounted the client's storage too.
      expect(hostMountUrl, isNotNull);
      final hr = await http.getUrl(Uri.parse('${hostMountUrl}client.txt'));
      expect(await (await hr.close()).transform(utf8.decoder).join(), 'from client');
      http.close(force: true);

      await s.close();

      // Reconnect with the pairing key only (no password).
      final s2 = await ClientSession.connect(params(key: s.newPairKey));
      expect(s2.connected, isTrue);
      expect(s2.newPairKey, isNull);
      await s2.close();

      // A wrong key is rejected.
      await expectLater(ClientSession.connect(params(key: Uint8List(32))), throwsA(anything));

      // Revoking on the host blocks the key.
      await hostStore.removePaired(clientStore.deviceId);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await expectLater(ClientSession.connect(params(key: s.newPairKey)), throwsA(predicate((e) => '$e'.contains('no longer trusts'))));

      await host.stop();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
