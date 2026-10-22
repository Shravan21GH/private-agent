import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../services/notes_store.dart';

/// Your notes and the files Zax has created for you.
class NotesScreen extends StatelessWidget {
  const NotesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Notes & Files'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.sticky_note_2_outlined), text: 'Notes'),
              Tab(icon: Icon(Icons.insert_drive_file_outlined), text: 'Files'),
            ],
          ),
        ),
        body: const TabBarView(children: [_NotesTab(), _FilesTab()]),
      ),
    );
  }
}

class _NotesTab extends StatefulWidget {
  const _NotesTab();

  @override
  State<_NotesTab> createState() => _NotesTabState();
}

class _NotesTabState extends State<_NotesTab> {
  List<ZaxNote> _notes = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final notes = await NotesStore.instance.all();
    if (!mounted) return;
    setState(() {
      _notes = notes;
      _loading = false;
    });
  }

  Future<void> _edit({ZaxNote? note}) async {
    final controller = TextEditingController(text: note?.text ?? '');
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(note == null ? 'New note' : 'Edit note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved == null || saved.trim().isEmpty) return;
    if (note == null) {
      await NotesStore.instance.add(saved);
    } else {
      await NotesStore.instance.edit(note.id, saved);
    }
    await _reload();
  }

  Future<void> _delete(ZaxNote note) async {
    await NotesStore.instance.delete(note.id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _notes.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No notes yet.\nTap + or say "make a note: ..." in the chat.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: _notes.length,
              itemBuilder: (context, index) {
                final note = _notes[index];
                return ListTile(
                  title: Text(
                    note.text,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    DateFormat('d MMM y, h:mm a').format(note.createdAt),
                  ),
                  onTap: () => _edit(note: note),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(note),
                  ),
                );
              },
            ),
    );
  }
}

class _FilesTab extends StatefulWidget {
  const _FilesTab();

  @override
  State<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<_FilesTab> {
  List<File> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final files = await ZaxFiles.instance.list();
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  String _name(File file) => file.uri.pathSegments.last;

  Future<void> _open(File file) async {
    final text = await ZaxFiles.instance.read(file);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_name(file)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to the clipboard.')),
                );
              }
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(File file) async {
    await ZaxFiles.instance.delete(file);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_files.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No files yet.\nSay "create a file called ideas.txt with ..." '
            'in the chat.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _files.length,
      itemBuilder: (context, index) {
        final file = _files[index];
        return ListTile(
          leading: const Icon(Icons.insert_drive_file_outlined),
          title: Text(_name(file)),
          subtitle: Text(
            DateFormat('d MMM y, h:mm a').format(file.lastModifiedSync()),
          ),
          onTap: () => _open(file),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(file),
          ),
        );
      },
    );
  }
}
