import 'package:flutter/material.dart';
import '../services/project_file_store.dart';

/// Private workspace for creating and editing text/code files inside Zax.
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});
  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  final _store = ProjectFileStore.instance;
  List<ZaxEntry> _entries = [];
  String? _folder;
  bool _loading = true;
  String? _error;

  @override
  void initState() { super.initState(); _reload(); }

  Future<void> _reload() async {
    setState(() { _loading = true; _error = null; });
    try {
      final entries = await _store.list(_folder);
      if (!mounted) return;
      setState(() { _entries = entries; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = '$e'; _loading = false; });
    }
  }

  Future<String?> _askText(String title, {String initial = '', int lines = 1}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: Text(title), content: TextField(controller: controller, autofocus: true, minLines: lines, maxLines: lines > 1 ? 12 : 1,
        decoration: InputDecoration(labelText: lines > 1 ? 'Content' : 'Name')),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save'))],
    ));
    controller.dispose();
    return result;
  }

  Future<void> _newFolder() async {
    final name = await _askText('Create folder');
    if (name == null || name.trim().isEmpty) return;
    try { await _store.createFolder(name); await _reload(); }
    catch (e) { _say('$e'); }
  }

  Future<void> _newFile() async {
    final folder = _folder;
    if (folder == null) { _say('Open a folder first to create a file.'); return; }
    final name = await _askText('New file name (e.g. notes.md)');
    if (name == null || name.trim().isEmpty) return;
    final content = await _askText('File content', lines: 6);
    if (content == null) return;
    try { await _store.createFile(folder, name, content); await _reload(); }
    catch (e) { _say('$e'); }
  }

  Future<void> _openFile(String name) async {
    final folder = _folder;
    if (folder == null) return;
    try {
      final content = await _store.readFile(folder, name);
      final edited = await _askText('Edit $name', initial: content, lines: 8);
      if (edited != null) { await _store.writeFile(folder, name, edited); await _reload(); }
    } catch (e) { _say('$e'); }
  }

  void _say(String text) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text))); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_folder == null ? 'Zax Files' : _folder!), leading: _folder == null ? null : IconButton(icon: const Icon(Icons.arrow_back), onPressed: () { setState(() => _folder = null); _reload(); })),
    floatingActionButton: FloatingActionButton.extended(onPressed: _folder == null ? _newFolder : _newFile,
      icon: Icon(_folder == null ? Icons.create_new_folder_outlined : Icons.note_add_outlined), label: Text(_folder == null ? 'New folder' : 'New file')),
    body: _loading ? const Center(child: CircularProgressIndicator()) : _error != null ? Center(child: Text(_error!)) : _entries.isEmpty
      ? Center(child: Text(_folder == null ? 'No folders yet. Create a folder to start.' : 'This folder is empty. Create a file.'))
      : ListView.builder(padding: const EdgeInsets.all(12), itemCount: _entries.length, itemBuilder: (context, i) {
        final item = _entries[i];
        return Card(child: ListTile(leading: Icon(item.isFolder ? Icons.folder_outlined : Icons.description_outlined), title: Text(item.name),
          subtitle: item.isFolder ? const Text('Folder') : Text('${item.size} bytes'),
          onTap: () { if (item.isFolder) { setState(() => _folder = item.name); _reload(); } else { _openFile(item.name); } }));
      }),
  );
}
