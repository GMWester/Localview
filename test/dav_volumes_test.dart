import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/client.dart';
import 'package:localview/src/codec.dart';
import 'package:localview/src/files.dart';
import 'package:localview/src/host.dart';
import 'package:localview/src/protocol.dart';
import 'package:localview/src/storage.dart';

/// The viewer's drive (WebDAV) for an Android host that shares internal storage + an SD card.
void main() {
  testWidgets('WebDAV drive of an Android host lists volumes and serves files', (tester) async {
    HttpOverrides.global = null;
    await tester.runAsync(() async {
      final tmp = await Directory.systemTemp.createTemp('lv_dav');
      await Directory('${tmp.path}/emulated/0/Download').create(recursive: true);
      await File('${tmp.path}/sd/DCIM/a.txt').create(recursive: true).then((f) => f.writeAsString('hello'));
      final hostStore = AppStore.memory()
        ..tcpPort = 0
        ..shareFiles = true
        ..deviceName = 'My Android device'
        ..fsRoot = androidVolumesRoot([
          (name: 'Internal storage', path: '${tmp.path}/emulated/0'),
          (name: 'SD card (0123-4567)', path: '${tmp.path}/sd'),
        ]);
      await hostStore.setPassword('pw');
      final host = HostService(hostStore,
          externalCapture: () async => RawFrame(16, 16, 64, Uint8List(16 * 16 * 4), PixelFmt.rgba));
      await host.start();
      String? url;
      final s = await ClientSession.connect(
          ConnectParams(host: '127.0.0.1', port: host.boundPort!, password: 'pw', myId: 'pc', myName: 'PC', share: false, mount: true),
          onMount: (u, v) async => url = u);
      for (var i = 0; i < 50 && url == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(url, isNotNull, reason: 'the viewer starts a drive for the shared storage');
      // Windows maps http://... drives unreliably when the path has encoded spaces.
      expect(url, isNot(contains('%20')));
      expect(url, endsWith('/My_Android_device/'));
      final c = HttpClient();
      Future<(int, String)> req(String method, String u, {String depth = '1'}) async {
        final r = await c.openUrl(method, Uri.parse(u));
        r.headers.set('Depth', depth);
        final res = await r.close();
        return (res.statusCode, await utf8.decodeStream(res));
      }

      final root = await req('PROPFIND', url!);
      expect(root.$1, 207, reason: root.$2);
      expect(root.$2, contains('Internal'));
      expect(root.$2, contains('SD'));
      final sd = await req('PROPFIND', '${url!.endsWith('/') ? url : '$url/'}SD%20card%20(0123-4567)/DCIM/');
      expect(sd.$1, 207, reason: sd.$2);
      expect(sd.$2, contains('a.txt'));
      final get = await req('GET', '${url!.endsWith('/') ? url : '$url/'}SD%20card%20(0123-4567)/DCIM/a.txt', depth: '0');
      expect(get, (200, 'hello'));
      c.close();
      await s.close();
      await host.stop();
      await tmp.delete(recursive: true);
    });
  }, timeout: const Timeout(Duration(minutes: 2)));
}
