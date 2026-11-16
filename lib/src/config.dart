import 'dart:io';

/// Build-time variant. Built with `--dart-define=LV_MODE=lan` or `wan`.
const String kModeName = String.fromEnvironment('LV_MODE', defaultValue: 'lan');
final bool kIsWan = kModeName.toLowerCase() == 'wan';
final bool kIsLan = !kIsWan;

const String kAppVersion = '1.0.0';
const int kProtocolVersion = 1;

/// LAN and WAN variants use different ports so both can run on one machine.
int get kDefaultTcpPort => kIsWan ? 47900 : 47800;
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
