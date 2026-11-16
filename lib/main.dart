import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app_controller.dart';
import 'src/config.dart';
import 'src/storage.dart';
import 'src/ui/home_page.dart';

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
    final seed = kIsWan ? const Color(0xFF6C4BFF) : const Color(0xFF0E9F8E);
    return MaterialApp(
      title: 'Localview ${kModeName.toUpperCase()}',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: HomePage(app: app),
    );
  }
}
