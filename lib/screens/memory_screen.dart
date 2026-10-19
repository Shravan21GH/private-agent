import 'package:flutter/material.dart';
import '../services/memory_store.dart';

/// See, add, edit and delete everything Zax has been asked to remember.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  final MemoryStore _store = MemoryStore.instance;
  List<MemoryItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await _store.items();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm(String title, String message, String action) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    return result == true;
  }

  /// Asks for text (and optionally a project name). Returns null if cancelled.
  Future<({String text, String project})?> _ask({
    required String title,
    String initialText = '',
    bool askProject = false,
  }) async {
    final textController = TextEditingController(text: initialText);
    final projectController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: textController,
              autofocus: true,
              maxLines: 3,
              maxLength: MemoryStore.maxLength,
              decoration: const InputDecoration(labelText: 'Memory'),
            ),
            if (askProject)
              TextField(
                controller: projectController,
                decoration: const InputDecoration(labelText: 'Project (optional)'),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    final text = textController.text;
    final project = projectController.text;
    textController.dispose();
    projectController.dispose();
    if (ok != true) return null;
    return (text: text, project: project);
  }

  Future<void> _add() async {
    final answer = await _ask(title: 'Add a memory', askProject: true);
    if (answer == null) return;
    var result = await _store.remember(answer.text, project: answer.project);
    if (result.status == MemoryStatus.needsConfirmation) {
      final go = await _confirm('Save private information?', result.message, 'Save anyway');
      if (!go) return;
      result = await _store.remember(answer.text, project: answer.project, confirmedSensitive: true);
    }
    _say(result.message);
    await _reload();
  }

  Future<void> _edit(MemoryItem item) async {
    final answer = await _ask(title: 'Edit memory', initialText: item.text);
    if (answer == null) return;
    final result = await _store.edit(item.id, answer.text);
    _say(result.message);
    await _reload();
  }

  Future<void> _delete(MemoryItem item) async {
    final ok = await _confirm('Delete memory?', '"${item.text}" will be deleted for good.', 'Delete');
    if (!ok) return;
    await _store.delete(item.id);
    await _reload();
  }

  Future<void> _clearAll() async {
    if (_items.isEmpty) return;
    final ok = await _confirm(
      'Clear all memory?',
      'All ${_items.length} saved memories will be deleted for good. Your chats and tasks are not affected.',
      'Clear all',
    );
    if (!ok) return;
    await _store.clearAll();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memory'),
        actions: [
          IconButton(
            tooltip: 'Clear all memory',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _clearAll,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Zax only remembers what you ask it to save ("remember ..." in chat, or the Add button). '
                    'It never saves passwords, PINs, card numbers or API keys. '
                    'Each message sends only a few of the most relevant memories, found by matching words, '
                    'to your AI provider, so a memory worded very differently may be missed. '
                    'Chat history is separate and is not unlimited memory.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                if (_items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('Nothing saved yet.')),
                  ),
                for (final item in _items)
                  ListTile(
                    title: Text(item.text),
                    subtitle: Text(
                      item.project != null ? 'Project: ${item.project}' : item.kind,
                    ),
                    onTap: () => _edit(item),
                    trailing: IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _delete(item),
                    ),
                  ),
              ],
            ),
    );
  }
}
