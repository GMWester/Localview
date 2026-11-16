import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../client.dart';
import '../files.dart';

/// In-app browser for the remote device's storage (always available; on iOS it
/// is the way to reach remote files since iOS has no user-mountable drives).
class FilesPage extends StatefulWidget {
  const FilesPage({super.key, required this.session});
  final ClientSession session;
  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  String _path = '/';
  List<FsEntry>? _items;
  String? _error;
  double? _progress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _items = null;
      _error = null;
    });
    try {
      final l = await widget.session.files.list(_path);
      l.sort((a, b) => a.isDir != b.isDir ? (a.isDir ? -1 : 1) : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() => _items = l);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  void _cd(String p) {
    _path = p;
    _load();
  }

  String _join(String name) => _path == '/' ? '/$name' : '$_path/$name';

  Future<void> _download(FsEntry e) async {
    final messenger = ScaffoldMessenger.of(context);
    Directory dir;
    try {
      dir = (Platform.isIOS || Platform.isAndroid)
          ? await getApplicationDocumentsDirectory()
          : (await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory());
    } catch (_) {
      dir = await getApplicationDocumentsDirectory();
    }
    final out = File('${dir.path}${Platform.pathSeparator}${e.name}');
    final sink = out.openWrite();
    try {
      var off = 0;
      while (off < e.size) {
        final b = await widget.session.files.read(_join(e.name), off, kFsChunk);
        if (b.isEmpty) break;
        sink.add(b);
        off += b.length;
        setState(() => _progress = e.size == 0 ? 1 : off / e.size);
      }
      await sink.close();
      messenger.showSnackBar(SnackBar(content: Text('Saved to ${out.path}')));
    } catch (err) {
      await sink.close();
      messenger.showSnackBar(SnackBar(content: Text('Download failed: $err')));
    } finally {
      setState(() => _progress = null);
    }
  }

  String _size(int b) {
    if (b < 1024) return '$b B';
    if (b < 1 << 20) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1 << 30) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final parent = _path == '/' ? null : (_path.lastIndexOf('/') <= 0 ? '/' : _path.substring(0, _path.lastIndexOf('/')));
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.session.peerName}: $_path', overflow: TextOverflow.ellipsis),
        bottom: _progress == null ? null : PreferredSize(preferredSize: const Size.fromHeight(4), child: LinearProgressIndicator(value: _progress)),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : _items == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(children: [
                  if (parent != null) ListTile(leading: const Icon(Icons.arrow_upward), title: const Text('..'), onTap: () => _cd(parent)),
                  for (final e in _items!)
                    ListTile(
                      leading: Icon(e.isDir ? Icons.folder : Icons.insert_drive_file_outlined),
                      title: Text(e.name),
                      subtitle: e.isDir ? null : Text('${_size(e.size)} · ${e.mtime.toLocal().toString().substring(0, 16)}'),
                      trailing: e.isDir ? const Icon(Icons.chevron_right) : const Icon(Icons.download),
                      onTap: () => e.isDir ? _cd(_join(e.name)) : _download(e),
                    ),
                ]),
    );
  }
}
