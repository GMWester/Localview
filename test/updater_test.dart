import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/updater.dart';

void main() {
  test('version comparison', () {
    expect(compareVersions('1.2.0', '1.1.0'), 1);
    expect(compareVersions('v1.10.0', '1.9.3'), 1);
    expect(compareVersions('1.1.0', '1.1.0+5'), 0);
    expect(compareVersions('1.0.9', '1.1'), -1);
  });

  test('picks the file for this build (Linux tar.gz, LAN by default)', () {
    final p = assetPatternForThisBuild()!;
    expect(p.hasMatch('Localview-LAN-linux-x64.tar.gz'), isTrue);
    expect(p.hasMatch('Localview-WAN-linux-x64.tar.gz'), isFalse);
    expect(p.hasMatch('Localview-LAN-steamos-x64.tar.gz'), isFalse);
    expect(p.hasMatch('Localview-LAN-linux-arm64.tar.gz'), isFalse);
  });

  test("what's new is taken from the release notes", () {
    const body = "## What's new in 1.2.0\n- **Two-factor authentication**: codes.\n- *Animations* switch.\n\nOne release for every platform.\n\nSource-Commit: abc";
    expect(whatsNew(body), '• Two-factor authentication: codes.\n• Animations switch.');
    expect(whatsNew('One release for every platform.'), '');
  });
}
