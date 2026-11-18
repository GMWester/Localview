import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Remote file access carried inside the encrypted session.
///
/// Wire format of [kFsReq] / [kFsResp]: [type][u32 id][u32 jsonLen][json][binary data]
const int kFsReq = 0x40;
const int kFsResp = 0x41;
const int kFsChunk = 1024 * 1024;

Uint8List encodeFs(int type, int id, Map<String, Object?> json, [List<int>? data]) {
  final j = utf8.encode(jsonEncode(json));
  final out = Uint8List(9 + j.length + (data?.length ?? 0));
  final bd = ByteData.sublistView(out);
  bd.setUint8(0, type);
  bd.setUint32(1, id);
  bd.setUint32(5, j.length);
  out.setRange(9, 9 + j.length, j);
  if (data != null) out.setRange(9 + j.length, out.length, data);
  return out;
}

({int id, Map<String, dynamic> json, Uint8List data}) decodeFs(Uint8List m) {
  final bd = ByteData.sublistView(m);
  final id = bd.getUint32(1);
  final jl = bd.getUint32(5);
  final json = (jsonDecode(utf8.decode(Uint8List.sublistView(m, 9, 9 + jl))) as Map).cast<String, dynamic>();
  return (id: id, json: json, data: Uint8List.sublistView(m, 9 + jl));
}

class FsEntry {
  FsEntry(this.name, this.isDir, this.size, this.mtime);
  final String name;
  final bool isDir;
  final int size;
  final DateTime mtime;

  Map<String, Object?> toJson() => {'n': name, 'd': isDir, 's': size, 'm': mtime.millisecondsSinceEpoch};
  factory FsEntry.fromJson(Map j) => FsEntry(j['n'] as String, j['d'] as bool, j['s'] as int,
      DateTime.fromMillisecondsSinceEpoch(j['m'] as int, isUtc: true));
}

class FsException implements Exception {
  FsException(this.code);
  final String code;
  @override
  String toString() => 'FsException($code)';
}

/// Root that shares every Android storage volume (internal storage, SD cards, USB drives).
/// Followed by `:<json list of {n: name, p: path}>` when Android reported its volumes.
const String kAndroidVolumesRoot = 'android:volumes';

/// Root string for the volumes Android reported (StorageManager), see [kAndroidVolumesRoot].
String androidVolumesRoot(List<({String name, String path})> volumes) => volumes.isEmpty
    ? kAndroidVolumesRoot
    : '$kAndroidVolumesRoot:${jsonEncode([for (final v in volumes) {'n': v.name, 'p': v.path}])}';

/// Serves this device's storage to the peer. Virtual paths use '/' separators.
///
/// [root] == null means "Windows drive mode": '/' lists drive letters and
/// '/C/Users' maps to 'C:\Users'.
/// [root] == [kAndroidVolumesRoot] means "Android volume mode": '/' lists
/// "Internal storage" (/storage/emulated/0) and one "SD card (ID)" folder per
/// SD card or USB drive (/storage/ID).
class FsServer {
  FsServer(this.root, {this.storageDir = '/storage'}) : _reported = _parseVolumes(root);
  final String? root;

  /// Volumes as reported by Android (name -> mount point); empty: scan [storageDir].
  final Map<String, String> _reported;

  static Map<String, String> _parseVolumes(String? root) {
    if (root == null || !root.startsWith('$kAndroidVolumesRoot:')) return const {};
    try {
      final l = jsonDecode(root.substring(kAndroidVolumesRoot.length + 1)) as List;
      return {
        for (final v in l.cast<Map>())
          if (v['n'] is String && v['p'] is String && !(v['n'] as String).contains('/')) v['n'] as String: v['p'] as String,
      };
    } catch (_) {
      return const {};
    }
  }

  /// Where Android mounts storage volumes (overridable for tests).
  final String storageDir;

  static const internalName = 'Internal storage';
  static final _volumeName = RegExp(r'^SD card \(([A-Za-z0-9-]+)\)$');

  bool get _volumes => root?.startsWith(kAndroidVolumesRoot) ?? false;

  /// Volume folder name -> mount point.
  String _volumePath(String name) {
    if (_reported.isNotEmpty) {
      final p = _reported[name];
      if (p == null) throw FsException('not_found');
      return p;
    }
    if (name == internalName) return '$storageDir/emulated/0';
    final m = _volumeName.firstMatch(name);
    if (m == null) throw FsException('not_found');
    return '$storageDir/${m.group(1)}';
  }

  Future<List<FsEntry>> _listVolumes() async {
    final now = DateTime.now().toUtc();
    if (_reported.isNotEmpty) {
      return [for (final name in _reported.keys) FsEntry(name, true, 0, now)];
    }
    final out = [FsEntry(internalName, true, 0, now)];
    try {
      await for (final e in Directory(storageDir).list(followLinks: false)) {
        final id = e.path.substring(e.path.lastIndexOf('/') + 1);
        if (id == 'emulated' || id == 'self' || id.startsWith('.') || !RegExp(r'^[A-Za-z0-9-]+$').hasMatch(id)) continue;
        try {
          // Only volumes this app can actually open (mounted and permitted).
          await Directory(e.path).list().first.timeout(const Duration(seconds: 2), onTimeout: () => e);
        } on StateError {
          // empty volume: still usable
        } catch (_) {
          continue;
        }
        out.add(FsEntry('SD card ($id)', true, 0, now));
      }
    } catch (_) {}
    return out;
  }

  String _real(String virt) {
    final parts = virt.split('/').where((p) => p.isNotEmpty && p != '.').toList();
    if (parts.any((p) => p == '..' || p.contains('\\') || p.contains('\x00'))) throw FsException('bad_path');
    if (_volumes) {
      if (parts.isEmpty) return '';
      final base = _volumePath(parts.first);
      return parts.length == 1 ? base : '$base/${parts.skip(1).join('/')}';
    }
    if (root == null) {
      if (parts.isEmpty) return '';
      final drive = parts.first;
      if (!RegExp(r'^[A-Za-z]$').hasMatch(drive)) throw FsException('not_found');
      return '${drive.toUpperCase()}:\\${parts.skip(1).join('\\')}';
    }
    final r = root!.endsWith('/') && root!.length > 1 ? root!.substring(0, root!.length - 1) : root!;
    if (parts.isEmpty) return r;
    return r == '/' ? '/${parts.join('/')}' : '$r/${parts.join('/')}';
  }

  Future<FsEntry> _stat(String real, String name) async {
    final st = await FileStat.stat(real);
    if (st.type == FileSystemEntityType.notFound) throw FsException('not_found');
    final dir = st.type == FileSystemEntityType.directory;
    return FsEntry(name, dir, dir ? 0 : st.size, st.modified.toUtc());
  }

  Future<List<FsEntry>> _drives() async {
    final out = <FsEntry>[];
    for (var c = 'A'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
      final l = String.fromCharCode(c);
      try {
        if (await Directory('$l:\\').exists()) out.add(FsEntry(l, true, 0, DateTime.now().toUtc()));
      } catch (_) {}
    }
    return out;
  }

  Future<(Map<String, Object?>, List<int>?)> handle(Map<String, dynamic> req, Uint8List data) async {
    try {
      final op = req['op'] as String;
      final path = req['path'] as String? ?? '/';
      final real = _real(path);
      final isWinRoot = (root == null || _volumes) && real.isEmpty;
      switch (op) {
        case 'stat':
          if (isWinRoot) return ({'ok': true, 'e': FsEntry('', true, 0, DateTime.now().toUtc()).toJson()}, null);
          return ({'ok': true, 'e': (await _stat(real, path.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => ''))).toJson()}, null);
        case 'list':
          final List<FsEntry> entries;
          if (isWinRoot) {
            entries = _volumes ? await _listVolumes() : await _drives();
          } else {
            entries = [];
            await for (final e in Directory(real).list(followLinks: false)) {
              final name = e.path.substring(e.path.lastIndexOf(Platform.pathSeparator) + 1);
              try {
                entries.add(await _stat(e.path, name));
              } catch (_) {}
            }
          }
          return ({'ok': true, 'list': entries.map((e) => e.toJson()).toList()}, null);
        case 'read':
          final off = req['off'] as int? ?? 0;
          final len = min(req['len'] as int? ?? kFsChunk, 4 * kFsChunk);
          final f = await File(real).open();
          try {
            await f.setPosition(off);
            final b = await f.read(len);
            return ({'ok': true}, b);
          } finally {
            await f.close();
          }
        case 'write':
          final off = req['off'] as int? ?? 0;
          final f = await File(real).open(mode: req['trunc'] == true ? FileMode.write : FileMode.append);
          try {
            await f.setPosition(off);
            await f.writeFrom(data);
          } finally {
            await f.close();
          }
          return ({'ok': true}, null);
        case 'mkdir':
          await Directory(real).create(recursive: true);
          return ({'ok': true}, null);
        case 'delete':
          final t = await FileSystemEntity.type(real, followLinks: false);
          if (t == FileSystemEntityType.notFound) throw FsException('not_found');
          if (t == FileSystemEntityType.directory) {
            await Directory(real).delete(recursive: true);
          } else {
            await File(real).delete();
          }
          return ({'ok': true}, null);
        case 'move':
        case 'copy':
          final dst = _real(req['to'] as String);
          if (req['overwrite'] == true && await FileSystemEntity.type(dst) != FileSystemEntityType.notFound) {
            await handle({'op': 'delete', 'path': req['to']}, Uint8List(0));
          }
          final t = await FileSystemEntity.type(real);
          if (t == FileSystemEntityType.notFound) throw FsException('not_found');
          if (op == 'move') {
            try {
              if (t == FileSystemEntityType.directory) {
                await Directory(real).rename(dst);
              } else {
                await File(real).rename(dst);
              }
              return ({'ok': true}, null);
            } on FileSystemException {
              // cross-device: fall through to copy + delete
            }
          }
          await _copy(real, dst, t == FileSystemEntityType.directory);
          if (op == 'move') await handle({'op': 'delete', 'path': path}, Uint8List(0));
          return ({'ok': true}, null);
        case 'space':
          return ({'ok': true, 'free': -1}, null);
      }
      throw FsException('bad_op');
    } on FsException catch (e) {
      return ({'ok': false, 'err': e.code}, null);
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode;
      final err = (code == 2 || code == 3) ? 'not_found' : (code == 5 || code == 13 || code == 1) ? 'denied' : 'io';
      return ({'ok': false, 'err': err, 'msg': e.message}, null);
    } catch (e) {
      return ({'ok': false, 'err': 'io', 'msg': '$e'}, null);
    }
  }

  static Future<void> _copy(String src, String dst, bool dir) async {
    if (!dir) {
      await File(src).copy(dst);
      return;
    }
    await Directory(dst).create(recursive: true);
    await for (final e in Directory(src).list(followLinks: false)) {
      final name = e.path.substring(e.path.lastIndexOf(Platform.pathSeparator) + 1);
      await _copy(e.path, '$dst${Platform.pathSeparator}$name', e is Directory);
    }
  }
}

/// Issues file requests to the peer.
class FsClient {
  FsClient(this._send);
  final Future<void> Function(Uint8List) _send;
  int _next = 1;
  final Map<int, Completer<({Map<String, dynamic> json, Uint8List data})>> _pending = {};

  void onResponse(Uint8List m) {
    final r = decodeFs(m);
    _pending.remove(r.id)?.complete((json: r.json, data: r.data));
  }

  void failAll() {
    for (final c in _pending.values) {
      c.completeError(FsException('disconnected'));
    }
    _pending.clear();
  }

  Future<({Map<String, dynamic> json, Uint8List data})> raw(Map<String, Object?> req, [List<int>? data]) async {
    final id = _next++;
    final c = Completer<({Map<String, dynamic> json, Uint8List data})>();
    _pending[id] = c;
    await _send(encodeFs(kFsReq, id, req, data));
    final r = await c.future.timeout(const Duration(seconds: 60), onTimeout: () {
      _pending.remove(id);
      throw FsException('timeout');
    });
    if (r.json['ok'] != true) throw FsException(r.json['err'] as String? ?? 'io');
    return r;
  }

  Future<FsEntry> stat(String p) async => FsEntry.fromJson((await raw({'op': 'stat', 'path': p})).json['e'] as Map);
  Future<List<FsEntry>> list(String p) async =>
      ((await raw({'op': 'list', 'path': p})).json['list'] as List).map((e) => FsEntry.fromJson(e as Map)).toList();
  Future<Uint8List> read(String p, int off, int len) async =>
      (await raw({'op': 'read', 'path': p, 'off': off, 'len': len})).data;
  Future<void> write(String p, int off, List<int> data, {bool trunc = false}) =>
      raw({'op': 'write', 'path': p, 'off': off, 'trunc': trunc}, data);
  Future<void> mkdir(String p) => raw({'op': 'mkdir', 'path': p});
  Future<void> delete(String p) => raw({'op': 'delete', 'path': p});
  Future<void> move(String a, String b, {bool overwrite = true}) =>
      raw({'op': 'move', 'path': a, 'to': b, 'overwrite': overwrite});
  Future<void> copy(String a, String b, {bool overwrite = true}) =>
      raw({'op': 'copy', 'path': a, 'to': b, 'overwrite': overwrite});
}

/// Content type from the file name, so players and viewers know what they open.
String mimeTypeFor(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return const {
        'mp4': 'video/mp4', 'm4v': 'video/mp4', 'mkv': 'video/x-matroska', 'webm': 'video/webm', 'mov': 'video/quicktime',
        '3gp': 'video/3gpp', 'avi': 'video/x-msvideo', 'ts': 'video/mp2t',
        'mp3': 'audio/mpeg', 'm4a': 'audio/mp4', 'aac': 'audio/aac', 'ogg': 'audio/ogg', 'opus': 'audio/ogg', 'wav': 'audio/wav', 'flac': 'audio/flac',
        'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif', 'webp': 'image/webp', 'heic': 'image/heic',
        'heif': 'image/heif', 'dng': 'image/x-adobe-dng', 'bmp': 'image/bmp',
        'pdf': 'application/pdf', 'txt': 'text/plain', 'zip': 'application/zip', 'apk': 'application/vnd.android.package-archive',
      }[ext] ??
      'application/octet-stream';
}

/// Loopback WebDAV server exposing the peer's storage so the OS can mount it
/// as a drive (Windows mapped drive, macOS Finder volume, Linux GVfs, Android
/// Storage Access Framework). Only reachable from 127.0.0.1 and only under a
/// random secret path prefix.
class DavServer {
  DavServer(this.fs, this.label);
  final FsClient fs;
  final String label;
  HttpServer? _http;
  late final String token = List.generate(12, (_) => Random.secure().nextInt(36).toRadixString(36)).join();
  // URL-safe (no spaces: Windows' WebDAV drive mapping fails on encoded spaces); the friendly
  // name is shown through the drive label.
  late final String _labelSeg = () {
    final s = label.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.\-]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return s.isEmpty ? 'Localview' : s;
  }();

  int get port => _http!.port;
  String get prefix => '/$token/${Uri.encodeComponent(_labelSeg)}';
  String get url => 'http://127.0.0.1:$port$prefix/';
  String get volumeName => _labelSeg;

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http!.autoCompress = false;
    _http!.listen((r) => _handle(r).catchError((Object e) {
          try {
            r.response.statusCode = 500;
            r.response.close();
          } catch (_) {}
        }));
  }

  Future<void> stop() async => _http?.close(force: true);

  String? _virt(String rawPath) {
    final p = Uri.decodeFull(rawPath);
    final pre = '/$token/$_labelSeg';
    if (p == pre || p == '$pre/') return '/';
    if (p.startsWith('$pre/')) {
      var v = p.substring(pre.length);
      if (v.length > 1 && v.endsWith('/')) v = v.substring(0, v.length - 1);
      return v;
    }
    return null;
  }

  String _href(String virt, bool dir) {
    final segs = virt.split('/').where((s) => s.isNotEmpty).map(Uri.encodeComponent);
    final h = '$prefix/${segs.join('/')}';
    return dir && !h.endsWith('/') ? '$h/' : h;
  }

  static String _xml(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  static String _httpDate(DateTime d) => HttpDate.format(d.toUtc());

  String _propXml(String virt, FsEntry e) {
    final name = virt == '/' ? _labelSeg : e.name;
    return '<D:response><D:href>${_xml(_href(virt, e.isDir))}</D:href><D:propstat><D:prop>'
        '<D:displayname>${_xml(name)}</D:displayname>'
        '<D:resourcetype>${e.isDir ? '<D:collection/>' : ''}</D:resourcetype>'
        '${e.isDir ? '' : '<D:getcontentlength>${e.size}</D:getcontentlength><D:getcontenttype>${mimeTypeFor(e.name)}</D:getcontenttype>'}'
        '<D:getlastmodified>${_httpDate(e.mtime)}</D:getlastmodified>'
        '<D:creationdate>${e.mtime.toUtc().toIso8601String()}</D:creationdate>'
        '<D:getetag>"${e.mtime.millisecondsSinceEpoch.toRadixString(16)}-${e.size.toRadixString(16)}"</D:getetag>'
        '<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>'
        '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>';
  }

  static int _errStatus(Object e) => e is FsException
      ? switch (e.code) { 'not_found' => 404, 'denied' => 403, 'bad_path' => 400, _ => 500 }
      : 500;

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('DAV', '1,2');
    res.headers.set('MS-Author-Via', 'DAV');
    final pathRaw = req.uri.path;
    final v = _virt(pathRaw);
    if (v == null) {
      // Parents of the mount point: report an empty collection so clients can walk down.
      if (req.method == 'OPTIONS') return await _options(res);
      if (req.method == 'PROPFIND' && '$prefix/'.startsWith(pathRaw.endsWith('/') ? pathRaw : '$pathRaw/')) {
        await _drain(req);
        res.statusCode = 207;
        res.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
        res.write('<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:"><D:response><D:href>${_xml(pathRaw)}</D:href>'
            '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>');
        return await res.close();
      }
      res.statusCode = 404;
      return await res.close();
    }
    try {
      final lv = req.uri.queryParameters['lv'];
      if (lv != null) return await _jsonApi(req, v, lv);
      switch (req.method) {
        case 'OPTIONS':
          return await _options(res);
        case 'PROPFIND':
          await _drain(req);
          final depth = req.headers.value('Depth') ?? '1';
          final self = await fs.stat(v);
          final sb = StringBuffer('<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">');
          sb.write(_propXml(v, self));
          if (self.isDir && depth != '0') {
            for (final e in await fs.list(v)) {
              sb.write(_propXml(v == '/' ? '/${e.name}' : '$v/${e.name}', e));
            }
          }
          sb.write('</D:multistatus>');
          final body = utf8.encode(sb.toString());
          res.statusCode = 207;
          res.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
          res.contentLength = body.length;
          res.add(body);
          return await res.close();
        case 'GET':
        case 'HEAD':
          final st = await fs.stat(v);
          if (st.isDir) {
            res.headers.contentType = ContentType.html;
            if (req.method == 'GET') {
              final items = await fs.list(v);
              res.write('<html><body><h3>${_xml(v)}</h3><ul>');
              for (final e in items) {
                res.write('<li><a href="${_xml(_href(v == '/' ? '/${e.name}' : '$v/${e.name}', e.isDir))}">${_xml(e.name)}</a></li>');
              }
              res.write('</ul></body></html>');
            }
            return await res.close();
          }
          var start = 0, end = st.size - 1;
          final range = req.headers.value('Range');
          final m = range == null ? null : RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
          if (m != null && st.size > 0) {
            if (m.group(1)!.isEmpty) {
              start = max(0, st.size - int.parse(m.group(2)!));
            } else {
              start = int.parse(m.group(1)!);
              if (m.group(2)!.isNotEmpty) end = min(end, int.parse(m.group(2)!));
            }
            if (start > end) {
              res.statusCode = 416;
              return await res.close();
            }
            res.statusCode = 206;
            res.headers.set('Content-Range', 'bytes $start-$end/${st.size}');
          }
          res.headers.set('Accept-Ranges', 'bytes');
          res.headers.set('Last-Modified', _httpDate(st.mtime));
          res.headers.contentType = ContentType.parse(mimeTypeFor(v));
          res.contentLength = st.size == 0 ? 0 : end - start + 1;
          if (req.method == 'GET') {
            // Read-ahead: the next chunk is already on its way from the device while this one
            // is sent, so videos and big files stream at network speed instead of stop-and-go.
            var off = start;
            Future<Uint8List>? next = off <= end ? fs.read(v, off, min(kFsChunk, end - off + 1)) : null;
            while (next != null) {
              final b = await next;
              if (b.isEmpty) break;
              final after = off + b.length;
              next = after <= end ? fs.read(v, after, min(kFsChunk, end - after + 1)) : null;
              res.add(b);
              off = after;
              await res.flush();
            }
          }
          return await res.close();
        case 'PUT':
          var off = 0;
          final buf = BytesBuilder(copy: false);
          var first = true;
          await for (final chunk in req) {
            buf.add(chunk);
            if (buf.length >= kFsChunk) {
              final b = buf.takeBytes();
              await fs.write(v, off, b, trunc: first);
              first = false;
              off += b.length;
            }
          }
          if (first || buf.length > 0) {
            final b = buf.takeBytes();
            await fs.write(v, off, b, trunc: first);
          }
          res.statusCode = 201;
          return await res.close();
        case 'MKCOL':
          await _drain(req);
          await fs.mkdir(v);
          res.statusCode = 201;
          return await res.close();
        case 'DELETE':
          await fs.delete(v);
          res.statusCode = 204;
          return await res.close();
        case 'MOVE':
        case 'COPY':
          final dest = req.headers.value('Destination');
          final dv = dest == null ? null : _virt(Uri.parse(dest).path);
          if (dv == null) {
            res.statusCode = 400;
            return await res.close();
          }
          final overwrite = (req.headers.value('Overwrite') ?? 'T').toUpperCase() != 'F';
          bool existed = true;
          try {
            await fs.stat(dv);
          } catch (_) {
            existed = false;
          }
          if (existed && !overwrite) {
            res.statusCode = 412;
            return await res.close();
          }
          if (req.method == 'MOVE') {
            await fs.move(v, dv, overwrite: overwrite);
          } else {
            await fs.copy(v, dv, overwrite: overwrite);
          }
          res.statusCode = existed ? 204 : 201;
          return await res.close();
        case 'LOCK':
          await _drain(req);
          try {
            await fs.stat(v);
          } on FsException catch (e) {
            if (e.code == 'not_found') await fs.write(v, 0, const [], trunc: true);
          }
          final tok = 'opaquelocktoken:${List.generate(16, (_) => Random().nextInt(16).toRadixString(16)).join()}';
          res.headers.set('Lock-Token', '<$tok>');
          res.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
          res.write('<?xml version="1.0" encoding="utf-8"?><D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>'
              '<D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth>'
              '<D:timeout>Second-3600</D:timeout><D:locktoken><D:href>$tok</D:href></D:locktoken>'
              '<D:lockroot><D:href>${_xml(_href(v, false))}</D:href></D:lockroot></D:activelock></D:lockdiscovery></D:prop>');
          return await res.close();
        case 'UNLOCK':
          res.statusCode = 204;
          return await res.close();
        case 'PROPPATCH':
          final body = await utf8.decoder.bind(req).join();
          final names = RegExp(r'<(?:(\w+):)?(\w+)[\s/>]')
              .allMatches(body)
              .map((m) => m.group(2)!)
              .where((n) => !const {'propertyupdate', 'set', 'remove', 'prop', 'xml'}.contains(n))
              .toSet();
          res.statusCode = 207;
          res.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
          res.write('<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:" xmlns:Z="urn:schemas-microsoft-com:">'
              '<D:response><D:href>${_xml(_href(v, false))}</D:href><D:propstat><D:prop>'
              '${names.map((n) => '<Z:$n/>').join()}</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>');
          return await res.close();
        default:
          res.statusCode = 405;
          return await res.close();
      }
    } catch (e) {
      res.statusCode = _errStatus(e);
      return await res.close();
    }
  }

  /// Small JSON API used by the Android DocumentsProvider (HttpURLConnection
  /// cannot send WebDAV verbs).
  Future<void> _jsonApi(HttpRequest req, String v, String op) async {
    final res = req.response;
    Object? out;
    switch (op) {
      case 'stat':
        out = (await fs.stat(v)).toJson();
      case 'list':
        out = (await fs.list(v)).map((e) => e.toJson()).toList();
      case 'mkdir':
        await _drain(req);
        await fs.mkdir(v);
        out = true;
      case 'move':
        await _drain(req);
        await fs.move(v, req.uri.queryParameters['to']!, overwrite: false);
        out = true;
      default:
        res.statusCode = 400;
        return await res.close();
    }
    final body = utf8.encode(jsonEncode(out));
    res.headers.contentType = ContentType.json;
    res.contentLength = body.length;
    res.add(body);
    return await res.close();
  }

  Future<void> _options(HttpResponse res) async {
    res.headers.set('Allow', 'OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, PROPFIND, PROPPATCH, LOCK, UNLOCK');
    res.statusCode = 200;
    return await res.close();
  }

  static Future<void> _drain(HttpRequest r) async {
    await for (final _ in r) {}
  }
}
