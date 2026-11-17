import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app_controller.dart';
import 'src/background.dart';
import 'src/config.dart';
import 'src/platform/android.dart';
import 'src/storage.dart';
import 'src/ui/home_page.dart';
import 'src/ui/theme.dart';
import 'src/ui/viewer_home.dart';
import 'src/viewer_window.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await AppStore.load();
  // Extra window opened by another Localview window: only show that device / monitor.
  final viewer = await takeViewerLaunch();
  if (viewer != null) {
    store.readOnly = true;
    final app = AppController(store);
    await app.initViewer();
    runApp(LocalviewApp(app: app, viewer: viewer));
    return;
  }
  store.fsRoot = await _defaultFsRoot();
  // Already running (maybe hidden in the background): bring that window back instead.
  if (await showRunningInstance()) exit(0);
  final app = AppController(store);
  await app.init();
  runApp(LocalviewApp(app: app));
}

Future<String?> _defaultFsRoot() async {
  if (Platform.isWindows) return null; // all drive letters
  if (Platform.isAndroid) return AndroidBridge.storageRoot(); // internal storage + SD cards / USB drives
  if (Platform.isIOS) return (await getApplicationDocumentsDirectory()).path;
  return '/';
}

class LocalviewApp extends StatelessWidget {
  const LocalviewApp({super.key, required this.app, this.viewer});
  final AppController app;
  final ViewerLaunch? viewer;

  @override
  Widget build(BuildContext context) {
    final seed = switch (kModeName) { 'wan' => const Color(0xFF6C4BFF), 'combined' => const Color(0xFF2F6FED), _ => const Color(0xFF0E9F8E) };
    return ListenableBuilder(
      listenable: app.store,
      builder: (context, _) {
        final t = app.store.theme;
        setAnimationsEnabled(app.store.animations);
        return MaterialApp(
          title: viewer == null ? 'Localview $kModeLabel' : '${viewer!.title} - Localview',
          debugShowCheckedModeBanner: false,
          scrollBehavior: const LocalviewScrollBehavior(),
          theme: applyAnimationPreference(buildTheme(seed, Brightness.light)),
          darkTheme: applyAnimationPreference(buildTheme(seed, Brightness.dark, oled: t == 'oled')),
          builder: (context, child) => animationsEnabled
              ? child!
              : MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
          themeMode: switch (t) {
            'light' => ThemeMode.light,
            'dark' || 'oled' => ThemeMode.dark,
            _ => ThemeMode.system,
          },
          home: viewer == null ? HomePage(app: app) : ViewerHome(app: app, launch: viewer!),
        );
      },
    );
  }
}
