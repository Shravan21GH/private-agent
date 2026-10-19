import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One task or goal.
class ZaxTask {
  final String id;
  String title;
  bool done;
  final DateTime createdAt;
  DateTime? dueDate;
  bool dueHasTime;
  DateTime? completedAt;

  /// 'none', 'daily' or 'weekly'. A repeating task creates the next one when
  /// it is completed.
  String repeat;

  ZaxTask({
    required this.id,
    required this.title,
    this.done = false,
    required this.createdAt,
    this.dueDate,
    this.dueHasTime = false,
    this.completedAt,
    this.repeat = 'none',
  });

  /// A pending task is overdue once its due day (or due time) has passed.
  bool isOverdue(DateTime now) {
    final due = dueDate;
    if (done || due == null) return false;
    if (dueHasTime) return due.isBefore(now);
    return due.isBefore(DateTime(now.year, now.month, now.day));
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'done': done,
    'createdAt': createdAt.toIso8601String(),
    'dueDate': dueDate?.toIso8601String(),
    'dueHasTime': dueHasTime,
    'completedAt': completedAt?.toIso8601String(),
    'repeat': repeat,
  };

  static ZaxTask? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final title = raw['title'];
    final created = DateTime.tryParse('${raw['createdAt']}');
    if (id is! String || title is! String || created == null) return null;
    return ZaxTask(
      id: id,
      title: title,
      done: raw['done'] == true,
      createdAt: created,
      dueDate: raw['dueDate'] == null
          ? null
          : DateTime.tryParse('${raw['dueDate']}'),
      dueHasTime: raw['dueHasTime'] == true,
      completedAt: raw['completedAt'] == null
          ? null
          : DateTime.tryParse('${raw['completedAt']}'),
      repeat: raw['repeat'] == 'daily' || raw['repeat'] == 'weekly'
          ? raw['repeat'] as String
          : 'none',
    );
  }
}

/// "today", "tomorrow", "Fri 23 Oct", "today at 5:30 PM" ...
String describeDue(ZaxTask task, DateTime now) {
  final due = task.dueDate;
  if (due == null) return 'no due date';
  final today = DateTime(now.year, now.month, now.day);
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  final dueDay = DateTime(due.year, due.month, due.day);
  String day;
  if (dueDay == today) {
    day = 'today';
  } else if (dueDay == tomorrow) {
    day = 'tomorrow';
  } else {
    day = DateFormat('EEE d MMM').format(due);
  }
  final text = task.dueHasTime ? '$day at ${DateFormat('h:mm a').format(due)}' : day;
  return text;
}

/// "repeats daily" / "repeats weekly" / empty text.
String describeRepeat(ZaxTask task) =>
    task.repeat == 'none' ? '' : 'repeats ${task.repeat}';

/// Result of reading dates and times out of a sentence.
class ParsedWhen {
  final DateTime? when;
  final bool hasTime;

  /// The sentence with the date/time words removed.
  final String text;

  const ParsedWhen(this.when, this.hasTime, this.text);
}

/// Understands simple English dates and times: today, tomorrow, weekdays,
/// "at 5pm", "at 17:30", "in 20 minutes", "in 2 hours".
class DateWords {
  static const List<String> _weekdays = [
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
    'sunday',
  ];

  static ParsedWhen parse(String input, DateTime now) {
    var text = ' $input ';
    final today = DateTime(now.year, now.month, now.day);
    DateTime? exact;
    DateTime? day;
    int? hour;
    var minute = 0;
    var ambiguous = false;

    final rel = RegExp(
      r'\bin\s+(\d{1,3})\s*(minutes?|mins?|hours?|hrs?)\b',
      caseSensitive: false,
    ).firstMatch(text);
    if (rel != null) {
      final n = int.parse(rel.group(1)!);
      final unit = rel.group(2)!.toLowerCase();
      exact = now.add(unit.startsWith('h') ? Duration(hours: n) : Duration(minutes: n));
      text = text.replaceFirst(rel.group(0)!, ' ');
    }

    if (exact == null) {
      var m = RegExp(
        r'\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b',
        caseSensitive: false,
      ).firstMatch(text);
      m ??= RegExp(
        r'\b(?:for|by)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b',
        caseSensitive: false,
      ).firstMatch(text);
      if (m != null) {
        var h = int.parse(m.group(1)!);
        final mm = int.tryParse(m.group(2) ?? '') ?? 0;
        final ap = m.group(3)?.toLowerCase();
        if (ap == 'pm' && h < 12) h += 12;
        if (ap == 'am' && h == 12) h = 0;
        if (h < 24 && mm < 60) {
          hour = h;
          minute = mm;
          ambiguous = ap == null && h >= 1 && h <= 11;
          text = text.replaceFirst(m.group(0)!, ' ');
        }
      }
    }

    final tomorrowRe = RegExp(r'\btomorrow\b', caseSensitive: false);
    final todayRe = RegExp(r'\b(?:today|tonight)\b', caseSensitive: false);
    if (tomorrowRe.hasMatch(text)) {
      day = DateTime(now.year, now.month, now.day + 1);
      text = text.replaceAll(tomorrowRe, ' ');
    } else if (todayRe.hasMatch(text)) {
      day = today;
      text = text.replaceAll(todayRe, ' ');
    } else {
      for (var i = 0; i < _weekdays.length; i++) {
        final wm = RegExp(
          '\\b(?:on\\s+)?(?:next\\s+)?${_weekdays[i]}\\b',
          caseSensitive: false,
        ).firstMatch(text);
        if (wm != null) {
          var ahead = (i + 1 - now.weekday + 7) % 7;
          if (ahead == 0) ahead = 7;
          day = DateTime(now.year, now.month, now.day + ahead);
          text = text.replaceFirst(wm.group(0)!, ' ');
          break;
        }
      }
    }

    DateTime? when;
    var hasTime = false;
    if (exact != null) {
      when = exact;
      hasTime = true;
    } else if (hour != null) {
      final base = day ?? today;
      var candidate = DateTime(base.year, base.month, base.day, hour, minute);
      if (day == null && ambiguous && candidate.isBefore(now)) {
        // "at 5" when 5 in the morning has passed: mean 5 in the evening.
        candidate = DateTime(base.year, base.month, base.day, hour + 12, minute);
      }
      if (day == null && candidate.isBefore(now)) {
        candidate = DateTime(
          base.year,
          base.month,
          base.day + 1,
          candidate.hour,
          candidate.minute,
        );
      }
      when = candidate;
      hasTime = true;
    } else if (day != null) {
      when = day;
    }

    var cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    cleaned = cleaned.replaceAll(RegExp(r'^[\s:\-,]+'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\s+(?:on|at|by|for|in)$', caseSensitive: false), '');
    cleaned = cleaned.replaceAll(
      RegExp(r'^(?:to|that|called|named)\s+', caseSensitive: false),
      '',
    );
    cleaned = cleaned.trim();
    return ParsedWhen(when, hasTime, cleaned);
  }
}

/// Saves tasks and goals on the phone. Survives app restarts.
class TaskStore {
  TaskStore();

  static final TaskStore instance = TaskStore();

  static const String _key = 'zax_tasks_v1';
  static const Set<String> _stop = {
    'my', 'the', 'a', 'an', 'task', 'goal', 'todo', 'to', 'of', 'for', 'it',
    'that', 'this', 'as', 'done', 'finished', 'complete', 'completed',
  };

  List<ZaxTask>? _tasks;

  /// The task Zax last created or talked about, so "tick it" works.
  String? lastMentionedId;

  /// The next copy made by the most recent completion of a repeating task.
  ZaxTask? lastRepeatCreated;

  Future<List<ZaxTask>>? _loading;

  Future<List<ZaxTask>> _load() => _loading ??= _read();

  Future<List<ZaxTask>> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    final list = <ZaxTask>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        final items = decoded is Map ? decoded['tasks'] : decoded;
        if (items is! List) throw const FormatException('Unexpected format');
        for (final item in items) {
          final task = ZaxTask.fromJson(item);
          if (task != null) list.add(task);
        }
      } catch (_) {
        // Damaged data: keep a copy of it and start with an empty list.
        await prefs.setString('${_key}_corrupt_backup', raw);
        list.clear();
      }
    }
    _tasks = list;
    return list;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final data = {
      'version': 1,
      'tasks': (_tasks ?? []).map((t) => t.toJson()).toList(),
    };
    await prefs.setString(_key, jsonEncode(data));
  }

  static String _cleanTitle(String title) {
    final clean = title.trim().replaceAll(RegExp(r'\s+'), ' ');
    return clean.length > 200 ? clean.substring(0, 200).trim() : clean;
  }

  static bool _sameDay(DateTime? a, DateTime? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  Future<List<ZaxTask>> pending() async {
    final list = (await _load()).where((t) => !t.done).toList();
    list.sort((a, b) {
      final ad = a.dueDate;
      final bd = b.dueDate;
      if (ad == null && bd == null) return a.createdAt.compareTo(b.createdAt);
      if (ad == null) return 1;
      if (bd == null) return -1;
      return ad.compareTo(bd);
    });
    return list;
  }

  Future<List<ZaxTask>> completed() async {
    final list = (await _load()).where((t) => t.done).toList();
    list.sort((a, b) => (b.completedAt ?? b.createdAt).compareTo(a.completedAt ?? a.createdAt));
    return list;
  }

  /// Adds a task. If the same pending task already exists for that day,
  /// nothing new is created and [created] is false.
  Future<({ZaxTask task, bool created})> add(
    String title, {
    DateTime? due,
    bool hasTime = false,
    String repeat = 'none',
  }) async {
    final clean = _cleanTitle(title);
    if (clean.isEmpty) throw ArgumentError('The task title is empty.');
    final tasks = await _load();
    for (final t in tasks) {
      if (!t.done &&
          t.title.toLowerCase() == clean.toLowerCase() &&
          _sameDay(t.dueDate, due)) {
        lastMentionedId = t.id;
        return (task: t, created: false);
      }
    }
    final task = ZaxTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: clean,
      createdAt: DateTime.now(),
      dueDate: due,
      dueHasTime: due != null && hasTime,
      repeat: repeat == 'daily' || repeat == 'weekly' ? repeat : 'none',
    );
    tasks.add(task);
    await _save();
    lastMentionedId = task.id;
    return (task: task, created: true);
  }

  Future<bool> setDone(String id, bool done) async {
    final tasks = await _load();
    final i = tasks.indexWhere((t) => t.id == id);
    if (i < 0) return false;
    final task = tasks[i];
    task.done = done;
    task.completedAt = done ? DateTime.now() : null;
    lastRepeatCreated = null;
    if (done && task.repeat != 'none') {
      final next = _nextOccurrence(task, tasks);
      if (next != null) {
        tasks.add(next);
        lastRepeatCreated = next;
      }
    }
    await _save();
    return true;
  }

  /// The next copy of a repeating task, due on the first matching day that
  /// is today or later. Null if an identical pending task already exists.
  ZaxTask? _nextOccurrence(ZaxTask task, List<ZaxTask> all) {
    final step = task.repeat == 'weekly' ? 7 : 1;
    final today = DateTime.now();
    final startOfToday = DateTime(today.year, today.month, today.day);
    var base = task.dueDate ?? startOfToday;
    var guard = 0;
    do {
      base = DateTime(
        base.year,
        base.month,
        base.day + step,
        base.hour,
        base.minute,
      );
      guard++;
    } while (DateTime(base.year, base.month, base.day).isBefore(startOfToday) &&
        guard < 800);
    for (final t in all) {
      if (!t.done && t.title.toLowerCase() == task.title.toLowerCase() && _sameDay(t.dueDate, base)) {
        return null;
      }
    }
    return ZaxTask(
      id: '${DateTime.now().microsecondsSinceEpoch}r',
      title: task.title,
      createdAt: DateTime.now(),
      dueDate: base,
      dueHasTime: task.dueHasTime,
      repeat: task.repeat,
    );
  }

  Future<bool> update(
    String id, {
    String? title,
    DateTime? due,
    bool? hasTime,
    bool clearDue = false,
    String? repeat,
  }) async {
    final tasks = await _load();
    final i = tasks.indexWhere((t) => t.id == id);
    if (i < 0) return false;
    final t = tasks[i];
    if (title != null) {
      final clean = _cleanTitle(title);
      if (clean.isEmpty) return false;
      t.title = clean;
    }
    if (clearDue) {
      t.dueDate = null;
      t.dueHasTime = false;
    } else if (due != null) {
      t.dueDate = due;
      t.dueHasTime = hasTime ?? false;
    }
    if (repeat != null) {
      t.repeat = repeat == 'daily' || repeat == 'weekly' ? repeat : 'none';
    }
    await _save();
    return true;
  }

  Future<bool> delete(String id) async {
    final tasks = await _load();
    final before = tasks.length;
    tasks.removeWhere((t) => t.id == id);
    if (tasks.length == before) return false;
    if (lastMentionedId == id) lastMentionedId = null;
    await _save();
    return true;
  }

  /// Pending tasks that match the words in [phrase]. Best matches first.
  Future<List<ZaxTask>> findPending(String phrase) async {
    final words = phrase
        .toLowerCase()
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((w) => w.isNotEmpty && !_stop.contains(w))
        .toList();
    if (words.isEmpty) return [];
    final scored = <MapEntry<ZaxTask, int>>[];
    for (final t in await pending()) {
      final title = t.title.toLowerCase();
      final hits = words.where(title.contains).length;
      if (hits == words.length) scored.add(MapEntry(t, hits + 100));
    }
    if (scored.isEmpty) {
      for (final t in await pending()) {
        final title = t.title.toLowerCase();
        final hits = words.where(title.contains).length;
        if (hits * 2 >= words.length && hits > 0) scored.add(MapEntry(t, hits));
      }
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.map((e) => e.key).toList();
  }
}
