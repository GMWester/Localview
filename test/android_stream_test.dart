import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/client.dart';
import 'package:localview/src/codec.dart';
import 'package:localview/src/host.dart';
import 'package:localview/src/storage.dart';

/// Android hosts: natively compressed JPEG frames (sent only when the screen changed) and
/// viewer-requested rotation.
void main() {
  // A real 32x16 JPEG.
  final jpeg = base64Decode('/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYwLjMxLjEwMgD/2wBDAAgEBAQEBAUFBQUFBQYGBgYGBgYGBgYGBgYHBwcICAgHBwcGBgcHCAgICAkJCQgICAgJCQoKCgwMCwsODg4RERT/xABNAAEBAAAAAAAAAAAAAAAAAAAABgEBAQEAAAAAAAAAAAAAAAAAAAYHEAEAAAAAAAAAAAAAAAAAAAAAEQEAAAAAAAAAAAAAAAAAAAAA/8AAEQgAEAAgAwEiAAIRAAMRAP/aAAwDAQACEQMRAD8AiwEo38AB/9k=');

  testWidgets('JPEG frames reach the viewer; unchanged screens are not resent; rotation round-trips', (tester) async {
    HttpOverrides.global = null;
    await tester.runAsync(() async {
      var seq = 1;
      final asked = <int>[];
      final rotations = <String>[];
      final hostStore = AppStore.memory()..tcpPort = 0;
      await hostStore.setPassword('pw');
      final host = HostService(hostStore, externalJpeg: (last, maxSide, quality) async {
        asked.add(last);
        return last == seq ? null : JpegFrame(seq, 32, 16, jpeg);
      })
        ..onRotate = (mode) async {
          rotations.add(mode);
          return rotations.length == 1 ? 'permission' : null;
        };
      await host.start();
      final client = AppStore.memory();
      final s = await ClientSession.connect(ConnectParams(
          host: '127.0.0.1', port: host.boundPort!, password: 'pw', myId: client.deviceId, myName: 'PC', share: false));
      expect(s.peerRotate, isTrue);

      Future<void> until(bool Function() ok) async {
        for (var i = 0; i < 100 && !ok(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }

      await until(() => s.image.value != null);
      expect((s.screenW, s.screenH), (32, 16));
      expect((s.image.value!.width, s.image.value!.height), (32, 16));

      // Still screen: the host keeps asking with the last sequence number and sends nothing new.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(asked.where((a) => a == 1).length, greaterThan(3));

      // The screen changes: a new frame arrives.
      final before = s.image.value;
      seq = 2;
      await until(() => s.image.value != before);
      expect(s.image.value, isNot(before));

      // Rotation: the first request needs the permission, the second works.
      final results = <String?>[];
      s.onRotateResult = results.add;
      s.rotate('landscape');
      await until(() => results.isNotEmpty);
      expect(results.single, 'permission');
      s.rotate('landscape');
      await until(() => results.length == 2);
      expect(results.last, isNull);
      expect(rotations, ['landscape', 'landscape']);
      expect(s.rotation, 'landscape');

      await s.close();
      await host.stop();
    });
  }, timeout: const Timeout(Duration(minutes: 2)));
}
