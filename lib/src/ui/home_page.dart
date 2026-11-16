import 'dart:ui' show AppExitResponse;

import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../config.dart';
import 'devices_page.dart';
import 'this_device_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.app});
  final AppController app;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await widget.app.shutdown();
    return AppExitResponse.exit;
  }

  @override
  Widget build(BuildContext context) {
    final pages = [DevicesPage(app: widget.app), ThisDevicePage(app: widget.app)];
    final dests = [
      (Icons.devices_other, kIsWan ? 'My devices' : 'Nearby devices'),
      (Icons.computer, 'This device'),
    ];
    final wide = MediaQuery.sizeOf(context).width > 720;
    final title = Row(children: [
      const Icon(Icons.cast_connected),
      const SizedBox(width: 10),
      Text('Localview'),
      const SizedBox(width: 8),
      Chip(label: Text(kModeName.toUpperCase()), visualDensity: VisualDensity.compact),
    ]);
    if (wide) {
      return Scaffold(
        appBar: AppBar(title: title),
        body: Row(children: [
          NavigationRail(
            selectedIndex: _tab,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [for (final d in dests) NavigationRailDestination(icon: Icon(d.$1), label: Text(d.$2))],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: pages[_tab]),
        ]),
      );
    }
    return Scaffold(
      appBar: AppBar(title: title),
      body: pages[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [for (final d in dests) NavigationDestination(icon: Icon(d.$1), label: d.$2)],
      ),
    );
  }
}

IconData osIcon(String os) => switch (os) {
      'windows' => Icons.desktop_windows,
      'macos' => Icons.laptop_mac,
      'linux' => Icons.terminal,
      'android' => Icons.phone_android,
      'ios' => Icons.phone_iphone,
      _ => Icons.devices,
    };
