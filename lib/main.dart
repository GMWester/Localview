import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app_controller.dart';
import 'src/config.dart';
import 'src/storage.dart';
import 'src/ui/home_page.dart';
import 'src/ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await AppStore.load();
  store.fsRoot = await _defaultFsRoot();
  final app = AppController(store);
  await app.init();
  runApp(LocalviewApp(app: app));
}

Future<String?> _defaultFsRoot() async {
  if (Platform.isWindows) return null; // all drive letters
  if (Platform.isAndroid) return '/storage/emulated/0';
  if (Platform.isIOS) return (await getApplicationDocumentsDirectory()).path;
  return '/';
}

class LocalviewApp extends StatelessWidget {
  const LocalviewApp({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final seed = switch (kModeName) { 'wan' => const Color(0xFF6C4BFF), 'combined' => const Color(0xFF2F6FED), _ => const Color(0xFF0E9F8E) };
    return ListenableBuilder(
      listenable: app.store,
      builder: (context, _) {
        final t = app.store.theme;
        return MaterialApp(
          title: 'Localview $kModeLabel',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(seed, Brightness.light),
          darkTheme: buildTheme(seed, Brightness.dark, oled: t == 'oled'),
          themeMode: switch (t) {
            'light' => ThemeMode.light,
            'dark' || 'oled' => ThemeMode.dark,
            _ => ThemeMode.system,
          },
          home: HomePage(app: app),
        );
      },
    );
  }
}
