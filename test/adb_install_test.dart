import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/ui/adb_dialog.dart';

void main() {
  test('Platform-Tools zip unpacks into platform-tools/ with adb executable; ".." entries are skipped', () async {
    final a = Archive()
      ..add(ArchiveFile.bytes('platform-tools/adb', [1, 2, 3])..mode = 0x1ED)
      ..add(ArchiveFile.bytes('platform-tools/lib64/x.so', [4]))
      ..add(ArchiveFile.bytes('../evil', [5]));
    final root = Directory.systemTemp.createTempSync('pt');
    await extractPlatformTools(ZipEncoder().encodeBytes(a), root.path);
    final adb = File('${root.path}/platform-tools/adb');
    expect(adb.readAsBytesSync(), [1, 2, 3]);
    expect(File('${root.path}/platform-tools/lib64/x.so').existsSync(), isTrue);
    expect(File('${root.parent.path}/evil').existsSync(), isFalse);
    if (!Platform.isWindows) expect(adb.statSync().mode & 0x40, isNonZero);
    root.deleteSync(recursive: true);
  });
}
