import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/platform/linux_x11.dart';
import 'package:localview/src/platform/platform.dart';
import 'package:localview/src/protocol.dart';

/// Runs under Xvfb (CI: xvfb-run). Checks capture and pointer mapping for a chosen monitor.
void main() {
  final hasX = Platform.isLinux && (Platform.environment['DISPLAY'] ?? '').isNotEmpty;

  test('monitor list, round trip and fallback', () {
    final l = listMonitors();
    expect(l, isNotEmpty);
    expect(l.first.primary, isTrue);
    expect(l.where((m) => m.isAll).length, l.length > 1 ? 1 : 0);
    final j = MonitorInfo.fromJson(l.first.toJson());
    expect(j, l.first);
    expect(pickMonitor(l, 'does-not-exist'), l.first);
    expect(pickMonitor(const [], 'x'), isNull);
  }, skip: hasX ? false : 'needs an X display');

  test('capture and pointer stay inside the selected monitor', () async {
    final screen = listMonitors().first;
    // A "monitor" covering the right-hand part of the screen, as on a two-monitor desktop.
    final right = MonitorInfo('right', 'Right', screen.w ~/ 2, 40, screen.w ~/ 2, screen.h - 40);
    final cap = X11Capturer();
    final f = cap.capture(monitor: right)!;
    expect((f.width, f.height), (right.w, right.h));
    final full = cap.capture()!;
    expect((full.width, full.height), (screen.w, screen.h));
    cap.dispose();

    final inj = X11Injector();
    Future<(int, int)> mouse() async {
      final r = await Process.run('xdotool', ['getmouselocation', '--shell']);
      final v = {for (final l in (r.stdout as String).split('\n')) if (l.contains('=')) l.split('=')[0]: l.split('=')[1]};
      return (int.parse(v['X']!), int.parse(v['Y']!));
    }

    inj.inject(const PointerMove(0, 0), monitor: right);
    expect(await mouse(), (right.x, right.y));
    inj.inject(const PointerMove(1, 1), monitor: right);
    expect(await mouse(), (right.x + right.w - 1, right.y + right.h - 1));
    inj.inject(const PointerMove(0.5, 0.5), monitor: right);
    final (x, y) = await mouse();
    expect((x - (right.x + right.w ~/ 2)).abs() <= 1 && (y - (right.y + right.h ~/ 2)).abs() <= 1, isTrue);
    // Without a monitor: the primary monitor, as before.
    inj.inject(const PointerMove(0, 0));
    expect(await mouse(), (0, 0));
  }, skip: hasX && Process.runSync('which', ['xdotool']).exitCode == 0 ? false : 'needs X and xdotool');
}
