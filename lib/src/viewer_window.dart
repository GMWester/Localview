// Extra viewer windows: each shows one device / monitor in its own window.
//
// Desktop (Windows, Linux, macOS): a second Localview process started in viewer mode.
// Android (incl. Android XR and Meta Quest): a new task (ViewerActivity), which headsets
// show as a separate panel.
//
// A viewer window never logs in on its own: the window that opens it hands over a session
// ticket that the device issued after a full login (password / pairing key + authenticator
// code). The ticket only travels inside this app (environment of the child process or
// intent extras).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform/android.dart';

const _envVar = 'LOCALVIEW_VIEWER';

class ViewerLaunch {
  const ViewerLaunch({
    required this.host,
    required this.port,
    required this.ticketId,
    required this.ticketKey,
    required this.deviceName,
    this.deviceId,
    this.monitor,
    this.monitorName,
  });
  final String host;
  final int port;
  final String ticketId;
  final Uint8List ticketKey;
  final String deviceName;
  final String? deviceId;
  final String? monitor;
  final String? monitorName;

  String get title => monitorName == null ? deviceName : '$deviceName · $monitorName';

  Map<String, Object?> toJson() => {
        'host': host,
        'port': port,
        'tid': ticketId,
        'tkey': base64Encode(ticketKey),
        'name': deviceName,
        'id': deviceId,
        'monitor': monitor,
        'monitorName': monitorName,
      };

  static ViewerLaunch? tryParse(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final j = jsonDecode(s) as Map;
      return ViewerLaunch(
        host: j['host'] as String,
        port: j['port'] as int,
        ticketId: j['tid'] as String,
        ticketKey: base64Decode(j['tkey'] as String),
        deviceName: j['name'] as String? ?? 'Device',
        deviceId: j['id'] as String?,
        monitor: j['monitor'] as String?,
        monitorName: j['monitorName'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Whether this device can open extra viewer windows.
bool get canOpenViewerWindows =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS || Platform.isAndroid);

/// Opens [l] in a new window. Returns false if that is not possible here.
Future<bool> openViewerWindow(ViewerLaunch l) async {
  final payload = jsonEncode(l.toJson());
  try {
    if (Platform.isAndroid) {
      await androidChannel.invokeMethod('openWindow', {'launch': payload, 'title': l.title});
      return true;
    }
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // An AppImage must be started again through the .AppImage file (its mount ends with this process).
      final exe = Platform.environment['APPIMAGE'] ?? Platform.resolvedExecutable;
      await Process.start(exe, const [], environment: {_envVar: payload, 'LOCALVIEW_VIEWER_TITLE': '${l.title} - Localview'}, mode: ProcessStartMode.detached);
      return true;
    }
  } catch (e) {
    debugPrint('could not open a window: $e');
  }
  return false;
}

/// The viewer request this process / activity was started with, if it is a viewer window.
Future<ViewerLaunch?> takeViewerLaunch() async {
  if (Platform.isAndroid) {
    try {
      return ViewerLaunch.tryParse(await androidChannel.invokeMethod<String>('viewerLaunch'));
    } catch (_) {
      return null;
    }
  }
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    return ViewerLaunch.tryParse(Platform.environment[_envVar]);
  }
  return null;
}

/// Closes this viewer window (and its process / task).
Future<void> closeViewerWindow() async {
  if (Platform.isAndroid) {
    try {
      await androidChannel.invokeMethod('closeWindow');
      return;
    } catch (_) {}
    await SystemNavigator.pop();
    return;
  }
  exit(0);
}
