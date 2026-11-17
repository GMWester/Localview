import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal UPnP-IGD client: asks the router to forward the WAN port to this
/// device so other devices can reach it from the internet.
class Upnp {
  String? externalIp;
  String? error;
  String? _controlUrl, _service;

  Future<bool> mapPort(int port, {String protocol = 'TCP'}) async {
    try {
      final loc = await _discover();
      if (loc == null) {
        error = 'No UPnP router found. Forward TCP port $port to this device manually.';
        return false;
      }
      await _parse(loc);
      if (_controlUrl == null) {
        error = 'Router does not offer port mapping.';
        return false;
      }
      final local = await _localIpTowards(Uri.parse(loc).host);
      await _soap('AddPortMapping', {
        'NewRemoteHost': '',
        'NewExternalPort': '$port',
        'NewProtocol': protocol,
        'NewInternalPort': '$port',
        'NewInternalClient': local,
        'NewEnabled': '1',
        'NewPortMappingDescription': 'Localview',
        'NewLeaseDuration': '0',
      });
      final r = await _soap('GetExternalIPAddress', {});
      externalIp = RegExp(r'<NewExternalIPAddress>([^<]*)<').firstMatch(r)?.group(1);
      error = null;
      return true;
    } catch (e) {
      error = 'UPnP port mapping failed ($e). Forward TCP port $port manually.';
      return false;
    }
  }

  Future<void> unmapPort(int port) async {
    if (_controlUrl == null) return;
    try {
      await _soap('DeletePortMapping', {'NewRemoteHost': '', 'NewExternalPort': '$port', 'NewProtocol': 'TCP'});
    } catch (_) {}
  }

  Future<String?> _discover() async {
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final c = Completer<String?>();
    sock.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final d = sock.receive();
      if (d == null) return;
      final m = RegExp(r'^location:\s*(\S+)', caseSensitive: false, multiLine: true).firstMatch(utf8.decode(d.data, allowMalformed: true));
      if (m != null && !c.isCompleted) c.complete(m.group(1));
    });
    for (final st in ['urn:schemas-upnp-org:device:InternetGatewayDevice:1', 'urn:schemas-upnp-org:device:InternetGatewayDevice:2']) {
      final msg = 'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: $st\r\n\r\n';
      sock.send(utf8.encode(msg), InternetAddress('239.255.255.250'), 1900);
    }
    final r = await c.future.timeout(const Duration(seconds: 4), onTimeout: () => null);
    sock.close();
    return r;
  }

  Future<void> _parse(String location) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await http.getUrl(Uri.parse(location));
      final xml = await (await req.close()).transform(utf8.decoder).join();
      for (final svc in ['urn:schemas-upnp-org:service:WANIPConnection:2', 'urn:schemas-upnp-org:service:WANIPConnection:1',
        'urn:schemas-upnp-org:service:WANPPPConnection:1']) {
        final i = xml.indexOf('<serviceType>$svc</serviceType>');
        if (i < 0) continue;
        final m = RegExp(r'<controlURL>([^<]+)</controlURL>').firstMatch(xml.substring(i));
        if (m == null) continue;
        _service = svc;
        _controlUrl = Uri.parse(location).resolve(m.group(1)!.trim()).toString();
        return;
      }
    } finally {
      http.close();
    }
  }

  Future<String> _soap(String action, Map<String, String> args) async {
    final body = '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:$action xmlns:u="$_service">'
        '${args.entries.map((e) => '<${e.key}>${e.value}</${e.key}>').join()}</u:$action></s:Body></s:Envelope>';
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await http.postUrl(Uri.parse(_controlUrl!));
      req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
      req.headers.set('SOAPAction', '"$_service#$action"');
      req.write(body);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw HttpException('$action → HTTP ${res.statusCode}');
      return text;
    } finally {
      http.close();
    }
  }

  static Future<String> _localIpTowards(String host) async {
    final s = await Socket.connect(host, 80, timeout: const Duration(seconds: 3)).catchError((_) async =>
        await Socket.connect(host, 5000, timeout: const Duration(seconds: 3)));
    final ip = s.address.address;
    s.destroy();
    return ip;
  }
}

/// Lists this device's IPv4 LAN addresses.
Future<List<String>> localAddresses() async {
  try {
    final out = <String>[];
    for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in ni.addresses) {
        if (!a.isLoopback) out.add(a.address);
      }
    }
    return out;
  } catch (_) {
    return [];
  }
}
