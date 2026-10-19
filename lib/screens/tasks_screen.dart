import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/reminder_service.dart';
import '../services/task_store.dart';

/// Tasks and goals: pending and completed, with due dates, overdue marks,
/// editing, deleting (always asks first) and optional Clock-app reminders.
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  final TaskStore _store = TaskStore.instance;
  List<ZaxTask> _pending = [];
  List<ZaxTask> _completed = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final pending = await _store.pending();
    final completed = await _store.completed();
    if (!mounted) return;
    setState(() {
      _pending = pending;
      _completed = completed;
      _loading = false;
    });
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm(String title, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _toggle(ZaxTask task) async {
    await _store.setDone(task.id, !task.done);
    await _reload();
  }

  Future<void> _delete(ZaxTask task) async {
    final ok = await _confirm('Delete task?', '"${task.title}" will be deleted for good.');
    if (!ok) return;
    await _store.delete(task.id);
    await _reload();
  }

  Future<void> _edit([ZaxTask? existing]) async {
    final titleController = TextEditingController(text: existing?.title ?? '');
    DateTime? due = existing?.dueDate;
    var hasTime = existing?.dueHasTime ?? false;
    var remind = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final currentDue = due;
          return AlertDialog(
            title: Text(existing == null ? 'New task or goal' : 'Edit task'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: titleController,
                    autofocus: true,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(labelText: 'What needs to be done?'),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.event, size: 18),
                        label: Text(
                          currentDue == null
                              ? 'Add due date'
                              : DateFormat('EEE d MMM').format(currentDue),
                        ),
                        onPressed: () async {
                          final now = DateTime.now();
                          final picked = await showDatePicker(
                            context: ctx,
                            initialDate: currentDue ?? now,
                            firstDate: DateTime(now.year - 1),
                            lastDate: DateTime(now.year + 5),
                          );
                          if (picked == null) return;
                          setLocal(() {
                            due = DateTime(
                              picked.year,
                              picked.month,
                              picked.day,
                              hasTime ? (currentDue?.hour ?? 0) : 0,
                              hasTime ? (currentDue?.minute ?? 0) : 0,
                            );
                          });
                        },
                      ),
                      if (currentDue != null)
                        ActionChip(
                          avatar: const Icon(Icons.schedule, size: 18),
                          label: Text(hasTime ? DateFormat('h:mm a').format(currentDue) : 'Add time'),
                          onPressed: () async {
                            final picked = await showTimePicker(
                              context: ctx,
                              initialTime: TimeOfDay(
                                hour: hasTime ? currentDue.hour : 9,
                                minute: hasTime ? currentDue.minute : 0,
                              ),
                            );
                            if (picked == null) return;
                            setLocal(() {
                              due = DateTime(
                                currentDue.year,
                                currentDue.month,
                                currentDue.day,
                                picked.hour,
                                picked.minute,
                              );
                              hasTime = true;
                            });
                          },
                        ),
                      if (currentDue != null)
                        ActionChip(
                          label: const Text('Clear date'),
                          onPressed: () => setLocal(() {
                            due = null;
                            hasTime = false;
                            remind = false;
                          }),
                        ),
                    ],
                  ),
                  if (currentDue != null && hasTime)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Remind me (Clock alarm)'),
                      subtitle: const Text('Works up to 24 hours ahead.'),
                      value: remind,
                      onChanged: (v) => setLocal(() => remind = v),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  if (titleController.text.trim().isEmpty) return;
                  Navigator.pop(ctx, true);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    final title = titleController.text.trim();
    titleController.dispose();
    if (saved != true || title.isEmpty) return;

    final finalDue = due;
    final finalHasTime = hasTime;
    if (existing == null) {
      await _store.add(title, due: finalDue, hasTime: finalHasTime);
    } else {
      await _store.update(
        existing.id,
        title: title,
        due: finalDue,
        hasTime: finalHasTime,
        clearDue: finalDue == null,
      );
    }
    await _reload();

    if (remind && finalDue != null && finalHasTime) {
      final problem = await ReminderService().scheduleAt(finalDue, title);
      _say(
        problem == null
            ? 'Reminder request sent to your Clock app. Please check it to confirm the alarm.'
            : 'Could not set the reminder: $problem',
      );
    }
  }

  Widget _tile(ZaxTask task) {
    final now = DateTime.now();
    final overdue = task.isOverdue(now);
    return ListTile(
      leading: Checkbox(value: task.done, onChanged: (_) => _toggle(task)),
      title: Text(
        task.title,
        style: TextStyle(
          decoration: task.done ? TextDecoration.lineThrough : null,
        ),
      ),
      subtitle: Text(
        overdue ? '${describeDue(task, now)} · overdue' : describeDue(task, now),
        style: TextStyle(color: overdue ? Theme.of(context).colorScheme.error : null),
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'More',
        onSelected: (value) {
          if (value == 'edit') _edit(task);
          if (value == 'delete') _delete(task);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
      onTap: () => _edit(task),
    );
  }

  Widget _list(List<ZaxTask> tasks, String empty) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (tasks.isEmpty) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Text(empty, textAlign: TextAlign.center)),
      );
    }
    return ListView.builder(
      itemCount: tasks.length,
      itemBuilder: (_, i) => _tile(tasks[i]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Tasks & Goals'),
          bottom: TabBar(
            tabs: [
              Tab(text: 'Pending (${_pending.length})'),
              Tab(text: 'Completed (${_completed.length})'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _edit(),
          icon: const Icon(Icons.add),
          label: const Text('Add'),
        ),
        body: TabBarView(
          children: [
            _list(_pending, 'No pending tasks.\nTap Add, or tell Zax: "create a goal for today: ..."'),
            _list(_completed, 'Nothing completed yet.'),
          ],
        ),
      ),
    );
  }
}
