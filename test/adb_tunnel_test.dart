import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/client.dart';
import 'package:localview/src/codec.dart';
import 'package:localview/src/host.dart';
import 'package:localview/src/protocol.dart';
import 'package:localview/src/storage.dart';

/// ADB over Localview: a TCP service on the host (stands in for adbd) is reached through the
/// encrypted session via a local port on the viewer.
void main() {
  testWidgets('tunnels carry data both ways, in order, only when the host allows it', (tester) async {
    HttpOverrides.global = null;
    await tester.runAsync(() async {
      // "adbd": echoes everything back, then closes when the peer closes.
      final adbd = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      adbd.listen((s) => s.listen(s.add, onDone: () => s.close()));

      final hostStore = AppStore.memory()
        ..tcpPort = 0
        ..adbOverLocalview = true;
      await hostStore.setPassword('pw');
      final host = HostService(hostStore,
          externalCapture: () async => RawFrame(16, 16, 64, Uint8List(16 * 16 * 4), PixelFmt.rgba))
        ..onAdbInfo = () async => {'wireless': true, 'connect': [adbd.port], 'pairing': <int>[]};
      await host.start();
      final client = AppStore.memory();
      final s = await ClientSession.connect(ConnectParams(
          host: '127.0.0.1', port: host.boundPort!, password: 'pw', myId: client.deviceId, myName: 'PC', share: false));
      expect(s.peerAdb, isTrue);

      final info = await s.adbInfo();
      expect(info['allowed'], isTrue);
      expect(info['connect'], [adbd.port]);

      final local = (await s.forwardPort(adbd.port))!;
      expect(await s.forwardPort(adbd.port), local); // one listener per remote port

      // Two connections at once, 3 MB each way, byte-exact.
      Future<void> roundTrip(int seed) async {
        final payload = Uint8List.fromList(List.generate(3 << 20, (i) => (i * 31 + seed) & 0xFF));
        final c = await Socket.connect(InternetAddress.loopbackIPv4, local);
        final got = BytesBuilder(copy: false);
        final done = Completer<void>();
        c.listen((d) {
          got.add(d);
          if (got.length >= payload.length && !done.isCompleted) done.complete();
        });
        for (var off = 0; off < payload.length; off += 100000) {
          c.add(payload.sublist(off, min(off + 100000, payload.length)));
        }
        await done.future.timeout(const Duration(seconds: 60));
        expect(got.takeBytes(), payload);
        await c.close();
      }

      await Future.wait([roundTrip(1), roundTrip(7)]);

      // Turned off on the host: new tunnels are refused (the local connection is dropped).
      hostStore.adbOverLocalview = false;
      await hostStore.save();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect((await s.adbInfo())['allowed'], isFalse);
      final c = await Socket.connect(InternetAddress.loopbackIPv4, local);
      final closed = Completer<int>();
      var n = 0;
      c.listen((d) => n += d.length, onDone: () {
        if (!closed.isCompleted) closed.complete(n);
      }, onError: (Object _) {
        if (!closed.isCompleted) closed.complete(n); // dropped (reset): refused
      });
      c.add([1, 2, 3]);
      unawaited(c.flush().catchError((_) => c));
      expect(await closed.future.timeout(const Duration(seconds: 15)), 0);

      await s.close();
      await host.stop();
      await adbd.close();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
