import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// Global switch for UI animations (This device → Appearance). Change it with [setAnimationsEnabled].
bool animationsEnabled = true;

/// How much faster than real time animations run while they are off: every built-in
/// animation (switches, dropdown and popup menus, segmented buttons, tab and
/// navigation indicators, snack bars, tooltips…) then finishes in its first frame.
const double _instant = 1e-4;

/// Turns all UI animations on or off. Widgets that offer no way to switch their own
/// animation off (e.g. Switch, DropdownButton) are covered by speeding up the animation
/// clock; scrolling keeps its normal feel ([LocalviewScrollBehavior]).
void setAnimationsEnabled(bool on) {
  animationsEnabled = on;
  final dilation = on ? 1.0 : _instant;
  if (timeDilation != dilation) timeDilation = dilation;
}

/// Runs a scroll fling in real time even while the animation clock is sped up.
class _RealTimeSimulation extends Simulation {
  _RealTimeSimulation(this.inner, this.scale);
  final Simulation inner;
  final double scale;
  @override
  double x(double time) => inner.x(time * scale);
  @override
  double dx(double time) => inner.dx(time * scale) * scale;
  @override
  bool isDone(double time) => inner.isDone(time * scale);
}

class _RealTimeScrollPhysics extends ScrollPhysics {
  const _RealTimeScrollPhysics({super.parent});
  @override
  _RealTimeScrollPhysics applyTo(ScrollPhysics? ancestor) => _RealTimeScrollPhysics(parent: buildParent(ancestor));
  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    final sim = super.createBallisticSimulation(position, velocity);
    return sim == null || timeDilation == 1.0 ? sim : _RealTimeSimulation(sim, timeDilation);
  }
}

/// App-wide scroll behaviour: normal fling physics whether or not animations are on.
class LocalviewScrollBehavior extends MaterialScrollBehavior {
  const LocalviewScrollBehavior();
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      _RealTimeScrollPhysics(parent: super.getScrollPhysics(context));
}

/// Loading spinner that stays still when animations are off (a spinning indicator
/// would otherwise race on the sped-up clock).
Widget busyIndicator({double? strokeWidth, double? size}) {
  if (!animationsEnabled) return Icon(Icons.hourglass_top, size: size);
  return strokeWidth == null ? const CircularProgressIndicator() : CircularProgressIndicator(strokeWidth: strokeWidth);
}

/// Progress bar; without a known [value] it shows a still bar when animations are off.
Widget progressBar(double? value) =>
    LinearProgressIndicator(value: value ?? (animationsEnabled ? null : 0.0));

/// Animation style for dialogs and sheets (null = default animation).
AnimationStyle? dialogAnimation() => animationsEnabled ? null : AnimationStyle.noAnimation;

class _NoTransitions extends PageTransitionsBuilder {
  const _NoTransitions();
  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation, Widget child) =>
      child;
}

/// Removes page transitions and touch ripples when animations are off.
ThemeData applyAnimationPreference(ThemeData t) {
  if (animationsEnabled) return t;
  const none = _NoTransitions();
  return t.copyWith(
    pageTransitionsTheme: PageTransitionsTheme(builders: {for (final p in TargetPlatform.values) p: none}),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
  );
}

/// Builds the app themes. [oled] makes every background pure black so OLED
/// pixels switch off (saves battery, no glow in the dark / in VR headsets).
ThemeData buildTheme(Color seed, Brightness brightness, {bool oled = false}) {
  var scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  if (brightness == Brightness.light) return ThemeData(colorScheme: scheme, useMaterial3: true);
  if (!oled) {
    // Neutral grey dark mode: the seed colour only tints accents, not backgrounds.
    scheme = scheme.copyWith(
      surface: const Color(0xFF121212),
      surfaceDim: const Color(0xFF121212),
      surfaceBright: const Color(0xFF383838),
      surfaceContainerLowest: const Color(0xFF0C0C0C),
      surfaceContainerLow: const Color(0xFF1A1A1A),
      surfaceContainer: const Color(0xFF1F1F1F),
      surfaceContainerHigh: const Color(0xFF272727),
      surfaceContainerHighest: const Color(0xFF313131),
      onSurface: const Color(0xFFE6E6E6),
      onSurfaceVariant: const Color(0xFFBDBDBD),
      outline: const Color(0xFF8A8A8A),
      outlineVariant: const Color(0xFF3A3A3A),
      secondaryContainer: const Color(0xFF333333),
      onSecondaryContainer: const Color(0xFFE6E6E6),
      surfaceTint: Colors.transparent,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFF121212),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF121212), surfaceTintColor: Colors.transparent),
      navigationBarTheme: const NavigationBarThemeData(backgroundColor: Color(0xFF1A1A1A), surfaceTintColor: Colors.transparent),
      navigationRailTheme: const NavigationRailThemeData(backgroundColor: Color(0xFF121212)),
      cardTheme: const CardThemeData(color: Color(0xFF1E1E1E), surfaceTintColor: Colors.transparent),
      dialogTheme: const DialogThemeData(backgroundColor: Color(0xFF242424), surfaceTintColor: Colors.transparent),
      popupMenuTheme: const PopupMenuThemeData(color: Color(0xFF2A2A2A), surfaceTintColor: Colors.transparent),
      bottomSheetTheme: const BottomSheetThemeData(backgroundColor: Color(0xFF1E1E1E), surfaceTintColor: Colors.transparent),
    );
  }

  const black = Colors.black;
  scheme = scheme.copyWith(
    surface: black,
    surfaceDim: black,
    surfaceBright: const Color(0xFF1A1A1A),
    surfaceContainerLowest: black,
    surfaceContainerLow: const Color(0xFF070707),
    surfaceContainer: const Color(0xFF0D0D0D),
    surfaceContainerHigh: const Color(0xFF141414),
    surfaceContainerHighest: const Color(0xFF1B1B1B),
    onSurface: const Color(0xFFEDEDED),
    onSurfaceVariant: const Color(0xFFBDBDBD),
    outlineVariant: const Color(0xFF262626),
    secondaryContainer: const Color(0xFF262626),
    onSecondaryContainer: const Color(0xFFEDEDED),
    surfaceTint: Colors.transparent,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: black,
    canvasColor: black,
    dividerColor: const Color(0xFF262626),
    appBarTheme: const AppBarTheme(backgroundColor: black, surfaceTintColor: Colors.transparent, scrolledUnderElevation: 0),
    navigationBarTheme: const NavigationBarThemeData(backgroundColor: black, surfaceTintColor: Colors.transparent),
    navigationRailTheme: const NavigationRailThemeData(backgroundColor: black),
    cardTheme: const CardThemeData(
      color: black,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: Color(0xFF262626)),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Color(0xFF0D0D0D),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(24)),
        side: BorderSide(color: Color(0xFF262626)),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: Color(0xFF0D0D0D), surfaceTintColor: Colors.transparent),
    popupMenuTheme: const PopupMenuThemeData(color: Color(0xFF111111), surfaceTintColor: Colors.transparent),
    snackBarTheme: const SnackBarThemeData(backgroundColor: Color(0xFF1B1B1B), contentTextStyle: TextStyle(color: Color(0xFFEDEDED))),
  );
}
