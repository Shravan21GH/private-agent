import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// A named list of steps, like "morning operation". Each step is something
/// you could type to Zax ("open Gmail", "create a task: review emails for
/// today", "give me my briefing", "wait 5 seconds").
class Routine {
  final String id;
  String name;
  List<String> steps;
  final DateTime createdAt;

  Routine({
    required this.id,
    required this.name,
    required this.steps,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'steps': steps,
    'createdAt': createdAt.toIso8601String(),
  };

  static Routine? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final steps = raw['steps'];
    final created = DateTime.tryParse('${raw['createdAt']}');
    if (id is! String || name is! String || steps is! List || created == null) {
      return null;
    }
    return Routine(
      id: id,
      name: name,
      steps: steps.whereType<String>().toList(),
      createdAt: created,
    );
  }
}

/// Saves routines on the phone.
class RoutineStore {
  RoutineStore();

  static final RoutineStore instance = RoutineStore();

  static const String _key = 'zax_routines_v1';
  static const int maxSteps = 15;
  static const int maxRoutines = 30;

  // Words that do not help tell routines apart.
  static const Set<String> _generic = {
    'routine', 'operation', 'operations', 'macro', 'my', 'the', 'a', 'an',
    'run', 'start', 'begin', 'do', 'execute', 'launch', 'activate',
  };

  List<Routine>? _items;
  Future<List<Routine>>? _loading;

  Future<List<Routine>> _load() => _loading ??= _read();

  Future<List<Routine>> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    final list = <Routine>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        final items = decoded is Map ? decoded['routines'] : decoded;
        if (items is! List) throw const FormatException('Unexpected format');
        for (final entry in items) {
          final routine = Routine.fromJson(entry);
          if (routine != null) list.add(routine);
        }
      } catch (_) {
        await prefs.setString('${_key}_corrupt_backup', raw);
        list.clear();
      }
    }
    _items = list;
    return list;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        'version': 1,
        'routines': (_items ?? []).map((r) => r.toJson()).toList(),
      }),
    );
  }

  static Set<String> _words(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.isNotEmpty && !_generic.contains(w))
      .toSet();

  static String _normal(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  Future<List<Routine>> all() async {
    final list = List<Routine>.from(await _load());
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  /// The routine whose name matches [query] ("morning operation",
  /// "run morning routine" and "morning" all find "Morning operation").
  Future<Routine?> find(String query) async {
    final items = await _load();
    final q = _normal(query);
    if (q.isEmpty) return null;
    for (final r in items) {
      if (_normal(r.name) == q) return r;
    }
    final queryWords = _words(query);
    if (queryWords.isEmpty) return null;
    for (final r in items) {
      final nameWords = _words(r.name);
      if (nameWords.isNotEmpty && nameWords.every(queryWords.contains) && queryWords.every(nameWords.contains)) {
        return r;
      }
    }
    return null;
  }

  /// Creates a routine, or replaces the steps of one with the same name.
  /// Returns null and a reason if the routine is not valid.
  Future<({Routine? routine, bool replaced, String? problem})> save(
    String name,
    List<String> steps,
  ) async {
    final cleanName = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    final cleanSteps = steps
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (cleanName.isEmpty || cleanName.length > 40) {
      return (routine: null, replaced: false, problem: 'A routine needs a name of up to 40 characters.');
    }
    if (cleanSteps.isEmpty) {
      return (routine: null, replaced: false, problem: 'A routine needs at least one step.');
    }
    if (cleanSteps.length > maxSteps) {
      return (routine: null, replaced: false, problem: 'A routine can have at most $maxSteps steps.');
    }
    final items = await _load();
    for (final r in items) {
      if (_normal(r.name) == _normal(cleanName)) {
        r.steps = cleanSteps;
        await _save();
        return (routine: r, replaced: true, problem: null);
      }
    }
    if (items.length >= maxRoutines) {
      return (routine: null, replaced: false, problem: 'You already have $maxRoutines routines. Delete one first.');
    }
    final routine = Routine(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: cleanName,
      steps: cleanSteps,
      createdAt: DateTime.now(),
    );
    items.add(routine);
    await _save();
    return (routine: routine, replaced: false, problem: null);
  }

  Future<bool> rename(String id, String newName) async {
    final clean = newName.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (clean.isEmpty || clean.length > 40) return false;
    final items = await _load();
    final i = items.indexWhere((r) => r.id == id);
    if (i < 0) return false;
    items[i].name = clean;
    await _save();
    return true;
  }

  Future<bool> setSteps(String id, List<String> steps) async {
    final clean = steps.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (clean.isEmpty || clean.length > maxSteps) return false;
    final items = await _load();
    final i = items.indexWhere((r) => r.id == id);
    if (i < 0) return false;
    items[i].steps = clean;
    await _save();
    return true;
  }

  Future<bool> delete(String id) async {
    final items = await _load();
    final before = items.length;
    items.removeWhere((r) => r.id == id);
    if (items.length == before) return false;
    await _save();
    return true;
  }
}
