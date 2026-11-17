import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/ui/theme.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Widget app(Widget child) => MaterialApp(
        scrollBehavior: const LocalviewScrollBehavior(),
        theme: applyAnimationPreference(ThemeData()),
        home: Scaffold(body: child),
      );

  testWidgets('animations off: a switch and a dropdown change in a single frame', (tester) async {
    setAnimationsEnabled(false);
    expect(timeDilation, lessThan(0.01));
    var on = false;
    int? picked = 15;
    await tester.pumpWidget(app(StatefulBuilder(
      builder: (context, set) => Column(children: [
        Switch(value: on, onChanged: (v) => set(() => on = v)),
        DropdownButton<int>(
          value: picked,
          items: const [DropdownMenuItem(value: 15, child: Text('15 fps')), DropdownMenuItem(value: 60, child: Text('60 fps'))],
          onChanged: (v) => set(() => picked = v),
        ),
      ]),
    )));
    await tester.tap(find.byType(Switch));
    await tester.pump(); // rebuild
    await tester.pump(const Duration(milliseconds: 16)); // one frame
    expect(on, isTrue);
    expect(tester.hasRunningAnimations, isFalse, reason: 'switch thumb must not animate');

    await tester.tap(find.text('15 fps'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.hasRunningAnimations, isFalse, reason: 'dropdown menu must open without animating');
    await tester.tap(find.text('60 fps').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(picked, 60);
    expect(tester.hasRunningAnimations, isFalse);
    setAnimationsEnabled(true);
  });

  testWidgets('animations on: the switch animates as usual', (tester) async {
    setAnimationsEnabled(true);
    var on = false;
    await tester.pumpWidget(app(StatefulBuilder(
      builder: (context, set) => Switch(value: on, onChanged: (v) => set(() => on = v)),
    )));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
  });

  testWidgets('animations off: a fling still scrolls over real time instead of jumping', (tester) async {
    setAnimationsEnabled(false);
    final controller = ScrollController();
    await tester.pumpWidget(app(ListView.builder(
      controller: controller,
      itemCount: 500,
      itemBuilder: (_, i) => SizedBox(height: 50, child: Text('item $i')),
    )));
    await tester.fling(find.byType(ListView), const Offset(0, -600), 2500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final early = controller.offset;
    await tester.pump(const Duration(milliseconds: 400));
    final later = controller.offset;
    expect(later, greaterThan(early), reason: 'the fling keeps moving after the first frames');
    await tester.pumpAndSettle();
    setAnimationsEnabled(true);
  });

  testWidgets('animations off: spinners are replaced by a still icon', (tester) async {
    setAnimationsEnabled(false);
    await tester.pumpWidget(app(Center(child: busyIndicator())));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
    setAnimationsEnabled(true);
  });
}
