import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/platform/linux_x11.dart';
import 'package:localview/src/protocol.dart';

void main() {
  final hasX = Platform.isLinux && (Platform.environment['DISPLAY'] ?? '').isNotEmpty;
  test('X11 capture and XTest injection', () {
    final cap = X11Capturer();
    final f = cap.capture()!;
    expect(f.width, greaterThan(0));
    expect(f.pixels.length, f.stride * f.height);
    final inj = X11Injector();
    inj.inject(const PointerMove(0.5, 0.5));
    inj.inject(const PointerButton(Btn.left, true));
    inj.inject(const PointerButton(Btn.left, false));
    inj.inject(const KeyInput(0x00070004, true));
    inj.inject(const KeyInput(0x00070004, false));
    inj.inject(const TextEntry('Ab1'));
    inj.inject(const Scroll(0, 2));
    cap.dispose();
  }, skip: hasX ? false : 'no X display');
}
