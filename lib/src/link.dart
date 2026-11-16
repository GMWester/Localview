import 'dart:async';
import 'dart:typed_data';

import 'files.dart';

/// File-sharing half of a session; identical on both ends.
class FileLink {
  FileLink({required this.send, required String? root, required bool share})
      : server = share ? FsServer(root) : null {
    client = FsClient(send);
  }

  final Future<void> Function(Uint8List) send;
  final FsServer? server;
  late final FsClient client;
  DavServer? dav;

  /// Returns true if [m] was a file message.
  bool handle(Uint8List m) {
    if (m.isEmpty) return false;
    if (m[0] == kFsResp) {
      client.onResponse(m);
      return true;
    }
    if (m[0] == kFsReq) {
      unawaited(_serve(m));
      return true;
    }
    return false;
  }

  Future<void> _serve(Uint8List m) async {
    final r = decodeFs(m);
    final srv = server;
    if (srv == null) {
      await send(encodeFs(kFsResp, r.id, {'ok': false, 'err': 'denied'}));
      return;
    }
    final (json, data) = await srv.handle(r.json, r.data);
    await send(encodeFs(kFsResp, r.id, json, data));
  }

  Future<DavServer> startDav(String label) async {
    final d = DavServer(client, label);
    await d.start();
    dav = d;
    return d;
  }

  Future<void> close() async {
    client.failAll();
    await dav?.stop();
    dav = null;
  }
}
