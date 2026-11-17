import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/files.dart';

void main() {
  test('Android volume mode lists internal storage and SD cards, and maps paths into them', () async {
    final storage = await Directory.systemTemp.createTemp('lv_storage');
    addTearDown(() => storage.delete(recursive: true));
    await Directory('${storage.path}/emulated/0/DCIM').create(recursive: true);
    await Directory('${storage.path}/self/primary').create(recursive: true);
    await Directory('${storage.path}/1A2B-3C4D/Music').create(recursive: true);
    await File('${storage.path}/1A2B-3C4D/Music/song.mp3').writeAsBytes([1, 2, 3]);

    final fs = FsServer(kAndroidVolumesRoot, storageDir: storage.path);
    Future<Map<String, Object?>> req(Map<String, dynamic> r, [List<int> data = const []]) async =>
        (await fs.handle(r, Uint8List.fromList(data))).$1;
    List<String> names(Map<String, Object?> res) =>
        (res['list'] as List).map((e) => (e as Map)['n'] as String).toList()..sort();

    final root = await req({'op': 'list', 'path': '/'});
    expect(root['ok'], isTrue);
    expect(names(root), ['Internal storage', 'SD card (1A2B-3C4D)']);

    expect(names(await req({'op': 'list', 'path': '/Internal storage'})), ['DCIM']);
    expect(names(await req({'op': 'list', 'path': '/SD card (1A2B-3C4D)/Music'})), ['song.mp3']);

    final read = await fs.handle({'op': 'read', 'path': '/SD card (1A2B-3C4D)/Music/song.mp3', 'off': 0, 'len': 10}, Uint8List(0));
    expect(read.$2, [1, 2, 3]);

    final w = await req({'op': 'write', 'path': '/SD card (1A2B-3C4D)/new.txt', 'off': 0, 'trunc': true}, [65]);
    expect(w['ok'], isTrue);
    expect(File('${storage.path}/1A2B-3C4D/new.txt').readAsStringSync(), 'A');

    // Unknown volumes and escapes are refused.
    expect((await req({'op': 'list', 'path': '/self'}))['ok'], isFalse);
    expect((await req({'op': 'list', 'path': '/SD card (1A2B-3C4D)/../..'}))['ok'], isFalse);
  });
}
