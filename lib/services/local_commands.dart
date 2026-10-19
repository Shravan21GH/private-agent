import 'package:intl/intl.dart';
import 'memory_store.dart';
import 'project_file_store.dart';
import 'reminder_service.dart';
import 'routine_store.dart';
import 'task_store.dart';

/// Sends a reminder request somewhere and returns null on success, or a
/// reason on failure.
typedef ReminderScheduler = Future<String?> Function(
  DateTime when,
  String label,
);

/// Commands about tasks, goals, reminders and memory that Zax carries out on
/// the phone itself, without asking the AI. Each one runs the real operation,
/// checks the result, and only then says it worked. Anything not clearly one
/// of these returns null so the message goes to the AI as normal.
class LocalCommands {
  LocalCommands({
    TaskStore? tasks,
    MemoryStore? memory,
    ProjectFileStore? files,
    RoutineStore? routines,
    ReminderScheduler? scheduleReminder,
    DateTime Function()? clock,
  }) : _tasks = tasks ?? TaskStore.instance,
       _memory = memory ?? MemoryStore.instance,
       _files = files ?? ProjectFileStore.instance,
       _routines = routines ?? RoutineStore.instance,
       _schedule = scheduleReminder ?? ReminderService().scheduleAt,
       _clock = clock ?? DateTime.now;

  final TaskStore _tasks;
  final MemoryStore _memory;
  final ProjectFileStore _files;
  final RoutineStore _routines;
  final ReminderScheduler _schedule;
  final DateTime Function() _clock;

  // When Zax asks "which one?", the answer "2" is handled briefly.
  List<String>? _pendingIds;
  DateTime? _pendingUntil;

  static final RegExp _prefix = RegExp(
    r'^(?:please\s+)?(?:(?:hey|ok)\s+)?(?:zax[,\s]+)?(?:please\s+)?',
    caseSensitive: false,
  );

  static final RegExp _addTask = RegExp(
    r'^(?:please\s+)?(?:create|add|make|set\s*up|set|new|save)\s+(?:me\s+)?'
    r'(?:a\s+|an\s+|new\s+)*(?:daily\s+)?(?:goal|task|to-?do|reminder)s?\b(.*)$',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _remindMe = RegExp(
    r'^(?:please\s+)?remind\s+me\s+(?:to\s+)?(.+)$',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _listTasks = RegExp(
    r"^(?:please\s+)?(?:show|list|see|what(?:'s|\s+is|\s+are)?|tell\s+me)\s+"
    r'(?:me\s+)?(?:all\s+)?(?:my\s+|the\s+)?'
    r'(pending\s+|completed\s+|done\s+|open\s+|finished\s+)?'
    r'(?:tasks|goals|to-?dos?)\b',
    caseSensitive: false,
  );

  static final RegExp _deleteTask = RegExp(
    r'^(?:please\s+)?(?:delete|remove)\s+(?:the\s+|my\s+)?(?:task|goal)\b',
    caseSensitive: false,
  );

  static final RegExp _remember = RegExp(
    r'^(?:please\s+)?(?:remember|memorize|save\s+to\s+memory|don.?t\s+forget)'
    r'\b\s*(anyway\b)?\s*(?:that\b)?\s*[:,\-]?\s*(.+)$',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _projectMemory = RegExp(
    r'^(?:for|in|on)\s+(?:the\s+)?project\s+(.+?)\s*[:\-]\s*(.+)$',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _listMemory = RegExp(
    r'^(?:what\s+do\s+you\s+(?:remember|know)\s+about\s+me|'
    r'(?:show|list)\s+(?:me\s+)?(?:my\s+|all\s+)?(?:saved\s+)?memor(?:y|ies)|'
    r'what\s+have\s+i\s+asked\s+you\s+to\s+remember)\s*\??$',
    caseSensitive: false,
  );

  static final RegExp _forgetMemory = RegExp(
    r'^(?:please\s+)?(?:(?:forget|delete|remove)\s+(?:the\s+|this\s+|that\s+|'
    r'my\s+|all\s+)?(?:memory|memories|saved\s+(?:facts|memories))|'
    r'forget\s+(?:everything|what\s+i\s+(?:told|said)))\b',
    caseSensitive: false,
  );

  static final RegExp _newProject = RegExp(
    r'^(?:please\s+)?(?:make|create|start|set\s*up|new)\s+(?:me\s+)?(?:a\s+|an\s+)?'
    r'(?:new\s+)?project\s+(?:called\s+|named\s+)?(.+)$',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _addToProject = RegExp(
    r'^(?:please\s+)?(?:save|store|put|add|keep)\s+(?:these\s+|this\s+|the\s+|my\s+)?'
    r'(?:codes?|scripts?|files?|notes?|details|code\s+files?)\s+(?:in|into|to)\s+'
    r'(?:the\s+)?(?:project\s+)?(.+?)\s*(?::|\n)\s*(.+)$',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _listProjects = RegExp(
    r'^(?:show|list|open)\s+(?:me\s+)?(?:my\s+|all\s+)?projects$',
    caseSensitive: false,
  );

  static final RegExp _showProject = RegExp(
    r'^(?:show|list|open)\s+(?:the\s+)?project\s+(.+)$',
    caseSensitive: false,
  );

  static final RegExp _defineRoutine = RegExp(
    r'^(?:please\s+)?(?:create|make|add|save|set\s*up|define|new)\s+(?:a\s+|an\s+|new\s+)*'
    r'(?:routine|operation|macro)\s+(?:called\s+|named\s+)?(.+?)\s*(?::|\n)\s*(.+)$',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _whenISay = RegExp(
    r'^when\s+i\s+say\s+(.+?)\s*[,:]\s*(.+)$',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _meansRoutine = RegExp(
    r'^(.{2,40}?)\s+means\s*:\s*(.+)$',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _listRoutines = RegExp(
    r'^(?:show|list)\s+(?:me\s+)?(?:my\s+|all\s+)?routines$',
    caseSensitive: false,
  );

  static final RegExp _runPrefix = RegExp(
    r'^(?:please\s+)?(?:run|start|begin|do|execute|launch|activate)\s+(?:my\s+|the\s+)?(.+)$',
    caseSensitive: false,
  );

  static final RegExp _briefing = RegExp(
    r"^(?:give\s+me\s+(?:a\s+|my\s+)?(?:daily\s+|morning\s+)?(?:briefing|summary)|"
    r"brief\s+me|(?:daily|morning)\s+briefing|what(?:'s|\s+is)\s+(?:my\s+day|on\s+today)|"
    r'what\s+do\s+i\s+have\s+(?:today|on\s+today))$',
    caseSensitive: false,
  );

  static const Map<String, String> _extensionForLanguage = {
    'lua': 'lua',
    'luau': 'luau',
    'python': 'py',
    'py': 'py',
    'javascript': 'js',
    'js': 'js',
    'typescript': 'ts',
    'ts': 'ts',
    'json': 'json',
    'dart': 'dart',
    'html': 'html',
    'css': 'css',
    'xml': 'xml',
    'yaml': 'yaml',
    'yml': 'yml',
    'kotlin': 'kt',
    'kt': 'kt',
    'java': 'java',
    'csharp': 'cs',
    'cs': 'cs',
    'cpp': 'cpp',
    'c': 'c',
    'markdown': 'md',
    'md': 'md',
    'csv': 'csv',
    'txt': 'txt',
    'text': 'txt',
  };

  /// Finds a routine explicitly requested by the user.
  Future<Routine?> routineToRun(String input) async {
    var text = input.trim().replaceAll(RegExp(r'[.!?]+$'), '');
    text = text.replaceFirst(_prefix, '').trim();

    if (text.isEmpty || text.contains('\n')) return null;

    final m = _runPrefix.firstMatch(text);
    final candidate = m != null ? m.group(1)! : text;

    if (candidate.split(RegExp(r'\s+')).length > 6) return null;

    return _routines.find(candidate);
  }

  /// Returns a local reply, or null when the AI should handle the message.
  Future<String?> handle(String input) async {
    var text = input.trim();
    if (text.isEmpty) return null;

    text = text.replaceFirst(_prefix, '').trim();
    if (text.isEmpty) return null;

    final clean = text.replaceAll(RegExp(r'[.!?]+$'), '').trim();
    final lower = clean.toLowerCase();

    try {
      final choice = await _handlePendingChoice(lower);
      if (choice != null) return choice;

      return await _handleMemory(text, clean, lower) ??
          await _handleProjects(text, clean, lower) ??
          await _handleRoutines(text, clean, lower) ??
          await _handleTasks(text, clean, lower);
    } catch (e) {
      return 'Something went wrong while doing that: $e';
    }
  }

  // ───────────────────────── Memory ─────────────────────────

  Future<String?> _handleMemory(
    String text,
    String clean,
    String lower,
  ) async {
    if (_listMemory.hasMatch(lower)) {
      final items = await _memory.items();

      if (items.isEmpty) {
        return 'I have nothing saved yet. Say "remember ..." and I will save it.';
      }

      final buffer =
          StringBuffer('Here is what you asked me to remember:\n');

      for (final item in items.take(15)) {
        final project = item.project;
        buffer.writeln(
          project != null ? '• [$project] ${item.text}' : '• ${item.text}',
        );
      }

      if (items.length > 15) {
        buffer.writeln('…and ${items.length - 15} more.');
      }

      buffer.write('You can edit or delete memories in Settings → Memory.');
      return buffer.toString();
    }

    if (_forgetMemory.hasMatch(lower)) {
      return 'To keep your data safe, I do not delete memories from chat. '
          'Open Settings → Memory to edit or delete them.';
    }

    final m = _remember.firstMatch(text);
    if (m == null) return null;

    final confirmed = m.group(1) != null;
    var rest = (m.group(2) ?? '').trim();

    // Questions are not saved as facts.
    if (rest.endsWith('?') ||
        RegExp(
          r'^(?:when|how|what|why|who|where|if)\b',
          caseSensitive: false,
        ).hasMatch(rest)) {
      return null;
    }

    String? project;
    final pm = _projectMemory.firstMatch(rest);

    if (pm != null) {
      project = pm.group(1)!.trim();
      rest = pm.group(2)!.trim();
    }

    final result = await _memory.remember(
      rest,
      project: project,
      confirmedSensitive: confirmed,
    );

    final saved = result.item;

    if (result.ok && saved != null) {
      return '${result.message} "${saved.text}"';
    }

    return result.message;
  }

  // ───────────────────────── Tasks ─────────────────────────

  Future<String?> _handleTasks(
    String text,
    String clean,
    String lower,
  ) async {
    if (_briefing.hasMatch(lower)) return _briefingReply();

    if (_deleteTask.hasMatch(lower)) {
      return 'To keep your data safe, I do not delete tasks from chat. '
          'Open Settings → Tasks & Goals and delete it there (it asks first).';
    }

    final list = _listTasks.firstMatch(lower);
    if (list != null) {
      return _listReply((list.group(1) ?? '').trim());
    }

    final add = _addTask.firstMatch(text);

    if (add != null) {
      final matchedText = add.group(0) ?? '';
      final capturedText = add.group(1) ?? '';

      // The captured task text is at the end of the full match.
      // Avoid add.start(1), which caused the reported build error.
      final head = matchedText
          .substring(0, matchedText.length - capturedText.length)
          .toLowerCase();

      return _createTask(
        capturedText,
        reminder: head.contains('reminder'),
      );
    }

    final remind = _remindMe.firstMatch(text);

    if (remind != null) {
      return _createTask(
        remind.group(1) ?? '',
        reminder: true,
      );
    }

    final target = _completeTarget(lower);
    if (target != null) return _completeTask(target);

    return null;
  }

  Future<String> _listReply(String which) async {
    final now = _clock();
    final wantsDone =
        which == 'completed' || which == 'done' || which == 'finished';

    if (wantsDone) {
      final done = await _tasks.completed();
      if (done.isEmpty) return 'You have no completed tasks yet.';

      final b = StringBuffer('Completed tasks:\n');

      for (final t in done.take(15)) {
        b.writeln('✓ ${t.title}');
      }

      return b.toString().trim();
    }

    final pending = await _tasks.pending();
    if (pending.isEmpty) return 'You have no pending tasks. 🎉';

    final b = StringBuffer('Pending tasks:\n');

    for (var i = 0; i < pending.length && i < 20; i++) {
      final t = pending[i];
      final overdue = t.isOverdue(now) ? '  ⚠ overdue' : '';
      final again = describeRepeat(t).isEmpty ? '' : '  ↻ ${t.repeat}';

      b.writeln(
        '${i + 1}. ${t.title} — ${describeDue(t, now)}$overdue$again',
      );
    }

    return b.toString().trim();
  }

  Future<String> _createTask(
    String raw, {
    required bool reminder,
  }) async {
    final now = _clock();
    var rest = raw.trim();

    rest = rest.replaceFirstMapped(
      RegExp(
        r"\bfor\s+(today|tomorrow|tonight)(?:'s)?(?:\s+(?:tasks?|goals?))?",
        caseSensitive: false,
      ),
      (m) => m.group(1)!,
    );

    rest = rest.replaceFirst(RegExp(r'^[\s:\-,]+'), '');

    var repeat = 'none';

    final dailyRe = RegExp(
      r'\b(?:every\s*day|everyday|daily|each\s+day)\b',
      caseSensitive: false,
    );

    final weeklyRe = RegExp(
      r'\b(?:every\s+week|weekly|each\s+week)\b',
      caseSensitive: false,
    );

    if (dailyRe.hasMatch(rest)) {
      repeat = 'daily';
      rest = rest.replaceAll(dailyRe, ' ');
    } else if (weeklyRe.hasMatch(rest)) {
      repeat = 'weekly';
      rest = rest.replaceAll(weeklyRe, ' ');
    }

    final parsed = DateWords.parse(rest, now);
    final title = parsed.text;

    if (title.isEmpty) {
      return reminder
          ? 'What should the reminder be about? For example: remind me to call mom at 5pm.'
          : 'What should the task be? For example: create a task: finish my science revision.';
    }

    final due = parsed.when ??
        (repeat != 'none'
            ? DateTime(now.year, now.month, now.day)
            : null);

    final result = await _tasks.add(
      title,
      due: due,
      hasTime: parsed.when != null && parsed.hasTime,
      repeat: repeat,
    );

    final task = result.task;

    final buffer = StringBuffer(
      result.created
          ? 'Saved task: "${task.title}" — due ${describeDue(task, now)}.'
          : 'You already have this task: "${task.title}" — due ${describeDue(task, now)}.',
    );

    if (repeat != 'none' && result.created) {
      buffer.write(' It repeats $repeat.');
    }

    if (reminder) {
      final when = parsed.when;

      if (when == null || !parsed.hasTime) {
        buffer.write(' You did not give a time, so no reminder was set.');
      } else {
        final problem = await _schedule(when, task.title);

        if (problem == null) {
          buffer.write(
            ' I sent a reminder request to your Clock app for ${describeDue(task, now)}. '
            'I cannot see inside the Clock app, so please check it to confirm the alarm is there.',
          );
        } else {
          buffer.write(' I could not set the reminder: $problem');
        }
      }
    }

    return buffer.toString();
  }

  /// Determines which task the user wants to complete.
  String? _completeTarget(String lower) {
    final tickIt = RegExp(
      r'(?:^|[.!?]\s*)(?:please\s+)?(?:tick|mark|cross)\s+(?:it|that)'
      r'(?:\s+(?:off|as\s+\w+))?\s*$',
    );

    if (tickIt.hasMatch(lower)) return 'it';

    if (RegExp(
      r'^(?:i\s+)?(?:have\s+)?(?:finished|completed|did|done)\s+(?:it|that)\b',
    ).hasMatch(lower)) {
      return 'it';
    }

    var m = RegExp(
      r'^(?:please\s+)?(?:tick|cross|mark|complete)\s+(?:off\s+)?(?:my\s+|the\s+)?'
      r'(.+?)(?:\s+as\s+(?:done|complete|completed|finished))?$',
    ).firstMatch(lower);

    m ??= RegExp(
      r'^(?:i\s+)?(?:have\s+)?(?:finished|completed|did|done)\s+(?:with\s+)?'
      r'(?:my\s+|the\s+)?(.+)$',
    ).firstMatch(lower);

    if (m == null) return null;

    final phrase = m.group(1)!.trim();
    return phrase.isEmpty ? null : phrase;
  }

  Future<String?> _completeTask(String target) async {
    final pending = await _tasks.pending();
    List<ZaxTask> matches;

    if (target == 'it') {
      final last = _tasks.lastMentionedId;
      final lastTask = pending.where((t) => t.id == last).toList();

      if (lastTask.isNotEmpty) {
        matches = lastTask;
      } else {
        matches = pending;
      }

      if (matches.isEmpty) {
        return 'You have no pending tasks to tick.';
      }
    } else {
      matches = await _tasks.findPending(target);
      if (matches.isEmpty) return null;
    }

    if (matches.length == 1) return _finish(matches.first);

    final now = _clock();
    final shown = matches.take(8).toList();

    _pendingIds = shown.map((t) => t.id).toList();
    _pendingUntil = now.add(const Duration(minutes: 2));

    final b = StringBuffer(
      'Which one did you finish? Reply with the number:\n',
    );

    for (var i = 0; i < shown.length; i++) {
      b.writeln(
        '${i + 1}. ${shown[i].title} — ${describeDue(shown[i], now)}',
      );
    }

    return b.toString().trim();
  }

  Future<String> _finish(ZaxTask task) async {
    final ok = await _tasks.setDone(task.id, true);

    if (!ok) {
      return 'I could not find "${task.title}" any more, so nothing was changed.';
    }

    final next = _tasks.lastRepeatCreated;
    final more = next == null
        ? ''
        : ' The next one is set for ${describeDue(next, _clock())}.';

    return 'Marked as done: "${task.title}" ✓$more';
  }

  Future<String?> _handlePendingChoice(String lower) async {
    final ids = _pendingIds;
    final until = _pendingUntil;

    if (ids == null || until == null) return null;

    if (_clock().isAfter(until)) {
      _pendingIds = null;
      return null;
    }

    final n = int.tryParse(lower);

    if (n == null) {
      _pendingIds = null;
      return null;
    }

    _pendingIds = null;

    if (n < 1 || n > ids.length) {
      return 'That number is not in the list. Nothing was changed.';
    }

    final pending = await _tasks.pending();
    final chosen = pending.where((t) => t.id == ids[n - 1]).toList();

    if (chosen.isEmpty) {
      return 'That task is not pending any more. Nothing was changed.';
    }

    return _finish(chosen.first);
  }

  // ───────────────────────── Briefing ─────────────────────────

  Future<String> _briefingReply() async {
    final now = _clock();
    final pending = await _tasks.pending();
    final overdue = pending.where((t) => t.isOverdue(now)).toList();

    final today = pending.where((t) {
      final d = t.dueDate;
      return d != null &&
          !t.isOverdue(now) &&
          d.year == now.year &&
          d.month == now.month &&
          d.day == now.day;
    }).toList();

    final routines = await _routines.all();

    final b = StringBuffer(
      '${DateFormat('EEEE, d MMMM').format(now)} · '
      '${DateFormat('h:mm a').format(now)}\n',
    );

    if (overdue.isEmpty && today.isEmpty) {
      b.writeln('Nothing is due today and nothing is overdue.');
    }

    if (overdue.isNotEmpty) {
      b.writeln('\n⚠ Overdue (${overdue.length}):');

      for (final t in overdue.take(5)) {
        b.writeln('• ${t.title} — ${describeDue(t, now)}');
      }
    }

    if (today.isNotEmpty) {
      b.writeln('\nDue today (${today.length}):');

      for (final t in today.take(8)) {
        b.writeln('• ${t.title}');
      }
    }

    final later = pending.length - overdue.length - today.length;

    if (later > 0) {
      b.writeln('\n$later more task(s) later or without a date.');
    }

    if (routines.isNotEmpty) {
      b.writeln(
        '\nRoutines you can run: ${routines.map((r) => r.name).join(', ')}.',
      );
    }

    return b.toString().trim();
  }

  // ───────────────────────── Routines ─────────────────────────

  List<String> _splitSteps(String body) {
    final parts = body.split(
      RegExp(
        r'\n+|;|\s+and\s+then\s+|\s+then\s+|(?:^|\s)\d+[.)]\s+',
        caseSensitive: false,
      ),
    );

    return parts
        .map((p) => p.trim().replaceFirst(RegExp(r'^[-•*]\s*'), '').trim())
        .where((p) => p.isNotEmpty)
        .toList();
  }

  Future<String?> _handleRoutines(
    String text,
    String clean,
    String lower,
  ) async {
    if (_listRoutines.hasMatch(lower)) {
      final routines = await _routines.all();

      if (routines.isEmpty) {
        return 'You have no routines yet. Say: create a routine called morning operation: '
            'open Gmail; create a task: review emails for today; give me my briefing';
      }

      final b = StringBuffer('Your routines:\n');

      for (final r in routines) {
        b.writeln('• ${r.name} (${r.steps.length} steps)');
      }

      b.write(
        'Say "run <name>" to start one. Edit or delete them in Settings → Routines.',
      );

      return b.toString();
    }

    var m = _defineRoutine.firstMatch(text);
    m ??= _whenISay.firstMatch(text);
    m ??= _meansRoutine.firstMat
