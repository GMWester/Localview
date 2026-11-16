import 'package:material_ui/material_ui.dart';

/// Builds the app themes. [oled] makes every background pure black so OLED
/// pixels switch off (saves battery, no glow in the dark / in VR headsets).
ThemeData buildTheme(Color seed, Brightness brightness, {bool oled = false}) {
  var scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  if (!oled) return ThemeData(colorScheme: scheme, useMaterial3: true);

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
    outlineVariant: const Color(0xFF262626),
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
