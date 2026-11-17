import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/client.dart';
import 'package:localview/src/codec.dart';
import 'package:localview/src/host.dart';
import 'package:localview/src/protocol.dart';
import 'package:localview/src/storage.dart';

void main() {
  testWidgets('Android-style host: sound route works without WebRTC and PCM reaches the viewer', (tester) async {
    HttpOverrides.global = null;
    await tester.runAsync(() async {
      final store = AppStore.memory()..tcpPort = 0;
      await store.setPassword('pw');
      final host = HostService(store,
          externalCapture: () async => RawFrame(32, 32, 128, Uint8List(32 * 32 * 4), PixelFmt.rgba))
        ..audioRouteCapable = true
        ..pcmAudioCapable = true;
      final pcm = Uint8List.fromList(List.generate(3841, (i) => i == 0 ? Msg.audioPcm : i & 0xff));
      host.onRtc = (sid, m) {
        if (m[0] == Msg.audioRoute) {
          host.sendRtc(sid, jsonMsg(Msg.audioRouteResult, {'mode': 'viewer'}));
          host.sendRtc(sid, pcm);
        }
      };
      await host.start();
      final c = await ClientSession.connect(ConnectParams(
          host: '127.0.0.1', port: host.boundPort!, password: 'pw', myId: 'v', myName: 'PC', share: false));
      expect(c.peerRtc, isFalse);
      expect(c.peerAudioRoute, isTrue);
      expect(c.peerPcmAudio, isTrue);
      final got = Completer<Uint8List>();
      final routed = Completer<String>();
      c.onAudioRoute = (mode, err) => routed.complete(mode);
      c.onAudioPcm = got.complete;
      c.setAudioRoute('viewer');
      expect(await routed.future.timeout(const Duration(seconds: 5)), 'viewer');
      final p = await got.future.timeout(const Duration(seconds: 5));
      expect(p, pcm.sublist(1));
      await c.close();
      await host.stop();
    });
  });
}
