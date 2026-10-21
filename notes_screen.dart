import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lightweight, on-device notes. Notes are never uploaded automatically.
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});
  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  static const _storageKey = 'zax_notes_v1';
  List<Map<String, dynamic>> _notes = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    final notes = <Map<String, dynamic>>[];
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map && item['title'] is String && item['body'] is String) {
              notes.add({'title': item['title'], 'body': item['body'], 'updated': item['updated'] ?? ''});
            }
          }
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() { _notes = notes; _loading = false; });
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(_notes));
  }

  Future<void> _edit({int? index}) async {
    final title = TextEditingController(text: index == null ? '' : _notes[index]['title'] as String);
    final body = TextEditingController(text: index == null ? '' : _notes[index]['body'] as String);
    final save = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(index == null ? 'New note' : 'Edit note'),
      content: SizedBox(width: 480, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: title, autofocus: true, maxLength: 100, decoration: const InputDecoration(labelText: 'Title')),
        TextField(controller: body, minLines: 4, maxLines: 10, decoration: const InputDecoration(labelText: 'Note')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save'))],
    ));
    if (save == true && title.text.trim().isNotEmpty) {
      final note = <String, dynamic>{'title': title.text.trim(), 'body': body.text.trim(), 'updated': DateTime.now().toIso8601String()};
      setState(() { if (index == null) { _notes.insert(0, note); } else { _notes[index] = note; } });
      await _persist();
    }
    title.dispose(); body.dispose();
  }

  Future<void> _delete(int index) async {
    final yes = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete note?'), content: Text('Delete “${_notes[index]['title']}”?'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete'))],
    ));
    if (yes == true) { setState(() => _notes.removeAt(index)); await _persist(); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Zax Notes')),
    floatingActionButton: FloatingActionButton.extended(onPressed: () => _edit(), icon: const Icon(Icons.note_add), label: const Text('New note')),
    body: _loading ? const Center(child: CircularProgressIndicator()) : _notes.isEmpty
      ? const Center(child: Text('No notes yet. Create one to keep ideas on this device.'))
      : ListView.builder(padding: const EdgeInsets.all(12), itemCount: _notes.length, itemBuilder: (context, i) => Card(
          child: ListTile(leading: const Icon(Icons.sticky_note_2_outlined), title: Text(_notes[i]['title'] as String),
            subtitle: Text(_notes[i]['body'] as String, maxLines: 3, overflow: TextOverflow.ellipsis),
            onTap: () => _edit(index: i), trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(i))))),
  );
}
