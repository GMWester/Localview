import 'dart:io';

/// Build-time variant: `--dart-define=LV_MODE=lan`, `wan` or `combined`
/// (combined = LAN discovery and WAN pairing in one app).
const String _rawMode = String.fromEnvironment('LV_MODE', defaultValue: 'lan');
final String kModeName = switch (_rawMode.toLowerCase()) { 'wan' => 'wan', 'combined' || 'all' || 'both' => 'combined', _ => 'lan' };
final bool kIsCombined = kModeName == 'combined';
final bool kHasLan = kModeName != 'wan';
final bool kHasWan = kModeName != 'lan';
String get kModeLabel => switch (kModeName) { 'wan' => 'WAN', 'combined' => 'LAN + WAN', _ => 'LAN' };

/// Set by CI from pubspec.yaml (--dart-define=LV_VERSION=...).
const String kAppVersion = String.fromEnvironment('LV_VERSION', defaultValue: '1.9.0');
const int kProtocolVersion = 1;

/// LAN and WAN variants use different ports so both can run on one machine.
int get kDefaultTcpPort => kHasWan ? 47900 : 47800;
const int kDiscoveryPort = 47801;

String get kOsName {
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  return Platform.operatingSystem;
}

/// Platforms on which this app can be controlled (act as a host).
/// iOS does not allow third-party apps to inject input, so it is viewer-only.
bool get kCanHost =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS || Platform.isAndroid;
