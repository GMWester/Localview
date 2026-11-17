// In-app updates: finds the newest release on GitHub, picks the file for this
// exact build (platform, flavor, processor, LAN/WAN/Combined) and installs it.
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'config.dart';

const String kReleaseRepo = 'GMWester/Localview';

/// Build flavor, set by CI: android | android-tv | android-xr | linux | steamos.
const String kFlavor = String.fromEnvironment('LV_FLAVOR', defaultValue: '');

class UpdateInfo {
  UpdateInfo(this.version, this.name, this.notes, this.pageUrl, this.assetName, this.assetUrl, this.assetSize);
  final String version, name, notes, pageUrl;
  final String? assetName, assetUrl;
  final int assetSize;
  bool get newer => compareVersions(version, kAppVersion) > 0;
}

int compareVersions(String a, String b) {
  List<int> p(String v) => v.replaceFirst(RegExp(r'^v'), '').split(RegExp(r'[.+-]')).map((x) => int.tryParse(x) ?? 0).toList();
  final x = p(a), y = p(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

String get _variantLabel => switch (kModeName) { 'wan' => 'WAN', 'combined' => 'Combined', _ => 'LAN' };

bool get _arm64 {
  final a = Abi.current();
  return a == Abi.linuxArm64 || a == Abi.macosArm64 || a == Abi.windowsArm64 || a == Abi.androidArm64;
}

/// How this copy was installed on Linux.
enum LinuxInstall { appImage, deb, rpm, archive }

LinuxInstall get linuxInstall {
  if ((Platform.environment['APPIMAGE'] ?? '').isNotEmpty) return LinuxInstall.appImage;
  if (Platform.resolvedExecutable.startsWith('/opt/localview-')) {
    try {
      if (Process.runSync('rpm', ['-q', 'localview-$kModeName']).exitCode == 0) return LinuxInstall.rpm;
    } catch (_) {}
    return LinuxInstall.deb;
  }
  return LinuxInstall.archive;
}

/// Android processor suffix of the per-processor APKs (null = use the all-in-one APK).
String? get androidAbiSuffix => switch (Abi.current()) {
      Abi.androidArm => 'armv7',
      Abi.androidArm64 => 'arm64',
      Abi.androidX64 => 'x86_64',
      _ => null,
    };

/// Matches a release file `<stem>-<version><ext>` (1.3.1 and later) or `<stem><ext>` (older releases).
RegExp _named(String stem, String ext) =>
    RegExp('^${RegExp.escape(stem)}(-[0-9]+(\\.[0-9]+)*)?${RegExp.escape(ext)}\$');

/// Release files for this build, best match first.
List<RegExp> assetPatternsForThisBuild() {
  if (Platform.isAndroid) {
    final l = _variantLabel;
    final f = kFlavor.isEmpty ? 'android' : kFlavor;
    final abi = androidAbiSuffix;
    return [
      if (abi != null) _named('Localview-$l-$f-$abi', '.apk'),
      _named('Localview-$l-$f', '.apk'),
    ];
  }
  final p = assetPatternForThisBuild();
  return [
    ?p,
    // Windows on ARM can also run the x64 build (emulated) if no ARM64 file exists.
    if (Platform.isWindows && _arm64) _named('Localview-$_variantLabel-windows-x64-setup', '.exe'),
  ];
}

/// Regex for the release file matching this build.
RegExp? assetPatternForThisBuild() {
  final l = _variantLabel;
  final arch = _arm64 ? 'arm64' : 'x64';
  String e(String s) => RegExp.escape(s);
  if (Platform.isWindows) return _named('Localview-$l-windows-$arch-setup', '.exe');
  if (Platform.isMacOS) return _named('Localview-$l-macos', '.dmg');
  if (Platform.isIOS) return _named('Localview-$l-ios-unsigned', '.ipa');
  if (Platform.isAndroid) {
    final f = kFlavor.isEmpty ? 'android' : kFlavor;
    return _named('Localview-$l-$f', '.apk');
  }
  if (Platform.isLinux) {
    final plat = kFlavor == 'steamos' ? 'steamos' : 'linux';
    return switch (linuxInstall) {
      LinuxInstall.appImage => _named('Localview-$l-$plat-$arch', '.AppImage'),
      LinuxInstall.deb => RegExp('^${e('localview-${kModeName}_')}.+_${_arm64 ? 'arm64' : 'amd64'}\\.deb\$'),
      LinuxInstall.rpm => RegExp('^${e('localview-$kModeName-')}.+\\.${_arm64 ? 'aarch64' : 'x86_64'}\\.rpm\$'),
      LinuxInstall.archive => _named('Localview-$l-$plat-$arch', '.tar.gz'),
    };
  }
  return null;
}

HttpClient _client() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 15)
  ..findProxy = HttpClient.findProxyFromEnvironment;

Future<UpdateInfo> checkForUpdate() async {
  final c = _client();
  try {
    final req = await c.getUrl(Uri.parse('https://api.github.com/repos/$kReleaseRepo/releases/latest'));
    req.headers.set('User-Agent', 'Localview/$kAppVersion');
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) throw HttpException('GitHub answered ${res.statusCode}');
    final j = jsonDecode(body) as Map<String, dynamic>;
    final all = (j['assets'] as List).cast<Map<String, dynamic>>();
    Map<String, dynamic>? asset;
    for (final pattern in assetPatternsForThisBuild()) {
      for (final a in all) {
        if (pattern.hasMatch(a['name'] as String)) {
          asset = a;
          break;
        }
      }
      if (asset != null) break;
    }
    final notes = whatsNew(j['body'] as String? ?? '');
    return UpdateInfo(
      (j['tag_name'] as String? ?? '').replaceFirst(RegExp(r'^v'), ''),
      j['name'] as String? ?? '',
      notes,
      j['html_url'] as String? ?? 'https://github.com/$kReleaseRepo/releases/latest',
      asset?['name'] as String?,
      asset?['browser_download_url'] as String?,
      asset?['size'] as int? ?? 0,
    );
  } finally {
    c.close();
  }
}

/// The "What's new" bullet list from a release description, as plain text.
String whatsNew(String body) {
  final m = RegExp(r"^## What's new[^\n]*\n([\s\S]*?)(\n\s*\n|\Z)", multiLine: true).firstMatch(body);
  if (m == null) return '';
  return m
      .group(1)!
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .map((l) => l.replaceFirst(RegExp(r'^\s*[-*]\s+'), '• ').replaceAll('**', '').replaceAll('*', ''))
      .join('\n');
}

/// Relaunches the (updated) app and quits this instance.
Future<void> restartApp() async {
  await Process.start(Platform.resolvedExecutable, const [], mode: ProcessStartMode.detached);
  exit(0);
}

const _android = MethodChannel('localview/android');

/// Downloads the update; [progress] gets 0..1. Returns the downloaded file.
Future<File> downloadUpdate(UpdateInfo u, void Function(double) progress) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}${u.assetName}');
  final c = _client();
  try {
    final req = await c.getUrl(Uri.parse(u.assetUrl!));
    req.headers.set('User-Agent', 'Localview/$kAppVersion');
    final res = await req.close();
    if (res.statusCode != 200) throw HttpException('download failed (${res.statusCode})');
    final total = res.contentLength > 0 ? res.contentLength : u.assetSize;
    final sink = file.openWrite();
    var got = 0;
    await for (final chunk in res) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) progress(got / total);
    }
    await sink.close();
    return file;
  } finally {
    c.close(force: true);
  }
}

/// Starts the platform's installer. Returns a message for the user, or null
/// when the app is about to quit/restart into the new version.
Future<String?> installUpdate(File f) async {
  final p = f.path;
  if (Platform.isWindows) {
    // Silent install over the current version; the installer restarts Localview.
    await Process.start(p, const ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'],
        mode: ProcessStartMode.detached);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }
  if (Platform.isMacOS) {
    await Process.run('open', [p]);
    return 'The disk image is open: drag Localview into Applications to replace the old version, then reopen it.';
  }
  if (Platform.isAndroid) {
    final r = await _android.invokeMethod<Object>('installApk', {'path': p});
    if (r == 'signature') {
      return 'This update is signed with a different key than the Localview installed here, so Android can\'t '
          'install it over it (older builds were signed with a temporary key). Uninstall Localview once, then '
          'install the new version from the release page or with the Localview Installer. Settings and saved '
          'devices are removed this one time; later updates install normally.';
    }
    return r == 'ok' || r == true ? null : 'Allow "Install unknown apps" for Localview, then press Update again.';
  }
  if (Platform.isLinux) {
    switch (linuxInstall) {
      case LinuxInstall.appImage:
        final target = Platform.environment['APPIMAGE']!;
        await Process.run('chmod', ['+x', p]);
        await f.copy('$target.new');
        await File('$target.new').rename(target);
        await Process.start(target, const [], mode: ProcessStartMode.detached);
        exit(0);
      case LinuxInstall.deb:
        final r = await Process.run('pkexec', ['apt-get', 'install', '-y', p]);
        if (r.exitCode == 0) return 'Updated. Restart Localview to use the new version.';
        await Process.run('xdg-open', [p]);
        return 'Install the opened package (or run: sudo apt install "$p"), then restart Localview.';
      case LinuxInstall.rpm:
        var r = await Process.run('pkexec', ['dnf', 'install', '-y', p]);
        if (r.exitCode != 0) r = await Process.run('pkexec', ['rpm', '-U', '--replacepkgs', p]);
        if (r.exitCode == 0) return 'Updated. Restart Localview to use the new version.';
        await Process.run('xdg-open', [p]);
        return 'Install the opened package (or run: sudo dnf install "$p"), then restart Localview.';
      case LinuxInstall.archive:
        final dest = File(Platform.resolvedExecutable).parent.path;
        final r = await Process.run('tar', ['xzf', p, '--strip-components=1', '-C', dest]);
        if (r.exitCode == 0) return 'Updated. Restart Localview to use the new version.';
        return 'Could not unpack the update: ${r.stderr}';
    }
  }
  debugPrint('no installer for this platform');
  return 'Download the new version from ${f.path}.';
}
