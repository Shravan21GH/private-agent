import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// One thing the user asked Zax to remember.
class MemoryItem {
  final String id;
  String text;

  /// 'fact', 'preference' or 'project'.
  String kind;
  String? project;
  final DateTime createdAt;
  DateTime updatedAt;

  MemoryItem({
    required this.id,
    required this.text,
    required this.kind,
    this.project,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'kind': kind,
    'project': project,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  static MemoryItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final text = raw['text'];
    final created = DateTime.tryParse('${raw['createdAt']}');
    if (id is! String || text is! String || created == null) return null;
    final kind = raw['kind'];
    final project = raw['project'];
    return MemoryItem(
      id: id,
      text: text,
      kind: kind is String ? kind : 'fact',
      project: project is String && project.isNotEmpty ? project : null,
      createdAt: created,
      updatedAt: DateTime.tryParse('${raw['updatedAt']}') ?? created,
    );
  }
}

enum MemoryStatus {
  saved,
  updated,
  duplicate,
  rejectedSecret,
  needsConfirmation,
  invalid,
  full,
}

class MemoryResult {
  final MemoryStatus status;
  final String message;
  final MemoryItem? item;

  const MemoryResult(this.status, this.message, [this.item]);

  /// True when the memory is now stored (new, updated or already there).
  bool get ok =>
      status == MemoryStatus.saved ||
      status == MemoryStatus.updated ||
      status == MemoryStatus.duplicate;
}

/// Memory that exists only because the user asked for it. Zax never saves
/// ordinary chat messages here. Everything is stored on this phone.
///
/// Honest limits: only a handful of the most relevant memories are sent to the
/// AI with each message, and they are matched by shared words, so a memory
/// phrased very differently from the question may not be found.
class MemoryStore {
  MemoryStore();

  static final MemoryStore instance = MemoryStore();

  static const String _key = 'zax_memory_v1';
  static const int maxItems = 200;
  static const int maxLength = 300;

  static const Set<String> _stop = {
    'the', 'and', 'that', 'this', 'with', 'for', 'are', 'was', 'were', 'you',
    'your', 'but', 'not', 'have', 'has', 'had', 'from', 'about', 'what',
    'when', 'where', 'who', 'how', 'why', 'can', 'will', 'just', 'its',
  };

  // Things that must never be kept in memory, even if the user asks.
  static final RegExp _secretPattern = RegExp(
    r'(password|passcode|\bpin\b|\botp\b|\bcvv\b|card number|credit card|'
    r'debit card|bank account|account number|aadhaar|aadhar|passport|\bssn\b|'
    r'social security|api key|secret key|private key|\btoken\b|'
    r'sk-[a-z0-9]{10,}|aiza[0-9a-z_-]{20,}|gsk_[a-z0-9]{10,}|\b\d{9,}\b)',
    caseSensitive: false,
  );

  // Private topics: saved only after the user explicitly confirms.
  static final RegExp _personalPattern = RegExp(
    r'(health|medical|medicine|medication|diagnos|disease|illness|salary|'
    r'income|\bdebt\b|religio|sexual|political)',
    caseSensitive: false,
  );

  static final RegExp _preferencePattern = RegExp(
    r"^(?:i\s+(?:prefer|like|love|hate|dislike|don'?t\s+like)|always|never|"
    r'please\s+always)\b',
    caseSensitive: false,
  );

  static bool looksSecret(String text) => _secretPattern.hasMatch(text);
  static bool looksPersonal(String text) => _personalPattern.hasMatch(text);

  List<MemoryItem>? _items;
  Future<List<MemoryItem>>? _loading;

  Future<List<MemoryItem>> _load() => _loading ??= _read();

  Future<List<MemoryItem>> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    final list = <MemoryItem>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        final items = decoded is Map ? decoded['items'] : decoded;
        if (items is! List) throw const FormatException('Unexpected format');
        for (final entry in items) {
          final item = MemoryItem.fromJson(entry);
          if (item != null) list.add(item);
        }
      } catch (_) {
        // Damaged data: keep a copy of it and start with an empty memory.
        await prefs.setString('${_key}_corrupt_backup', raw);
        list.clear();
      }
    }
    _items = list;
    return list;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final data = {
      'version': 1,
      'items': (_items ?? []).map((i) => i.toJson()).toList(),
    };
    await prefs.setString(_key, jsonEncode(data));
  }

  static Set<String> _tokens(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.length > 2 && !_stop.contains(w))
      .toSet();

  static double _similarity(String a, String b) {
    final ta = _tokens(a);
    final tb = _tokens(b);
    if (ta.isEmpty || tb.isEmpty) return 0;
    final shared = ta.intersection(tb).length;
    return shared / ta.union(tb).length;
  }

  static String _normal(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  /// All memories, newest first.
  Future<List<MemoryItem>> items() async {
    final list = List<MemoryItem>.from(await _load());
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  Future<MemoryResult> remember(
    String text, {
    String? project,
    String? kind,
    bool confirmedSensitive = false,
  }) async {
    final clean = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (clean.length < 3) {
      return const MemoryResult(
        MemoryStatus.invalid,
        'There is nothing to remember in that.',
      );
    }
    if (clean.length > maxLength) {
      return const MemoryResult(
        MemoryStatus.invalid,
        'That is too long for one memory (300 characters at most). '
        'Please shorten it.',
      );
    }
    if (looksSecret(clean)) {
      return const MemoryResult(
        MemoryStatus.rejectedSecret,
        'I never store passwords, PINs, card or ID numbers, or API keys in '
        'memory, so I did not save that.',
      );
    }
    if (!confirmedSensitive && looksPersonal(clean)) {
      return const MemoryResult(
        MemoryStatus.needsConfirmation,
        'That looks like private information (health, money or beliefs). '
        'I only save it if you confirm. Say "remember anyway: ..." to save it.',
      );
    }

    final proj = (project ?? '').trim();
    final theKind = proj.isNotEmpty
        ? 'project'
        : (kind ?? (_preferencePattern.hasMatch(clean) ? 'preference' : 'fact'));
    final items = await _load();

    for (final existing in items) {
      if (_normal(existing.text) == _normal(clean)) {
        return MemoryResult(
          MemoryStatus.duplicate,
          'I already have that saved.',
          existing,
        );
      }
    }
    for (final existing in items) {
      if ((existing.project ?? '') != proj || existing.kind != theKind) continue;
      final sim = _similarity(existing.text, clean);
      if (sim >= 0.8) {
        return MemoryResult(
          MemoryStatus.duplicate,
          'I already have something very similar saved.',
          existing,
        );
      }
      if (sim >= 0.5) {
        final old = existing.text;
        existing.text = clean;
        existing.updatedAt = DateTime.now();
        await _save();
        return MemoryResult(
          MemoryStatus.updated,
          'Updated an older, similar memory (it said: "$old"). '
          'You can change this in the Memory screen.',
          existing,
        );
      }
    }
    if (items.length >= maxItems) {
      return const MemoryResult(
        MemoryStatus.full,
        'Memory is full (200 items). Please delete some in the Memory screen.',
      );
    }
    final now = DateTime.now();
    final item = MemoryItem(
      id: now.microsecondsSinceEpoch.toString(),
      text: clean,
      kind: theKind,
      project: proj.isEmpty ? null : proj,
      createdAt: now,
      updatedAt: now,
    );
    items.add(item);
    await _save();
    return MemoryResult(MemoryStatus.saved, 'Saved to memory.', item);
  }

  /// Changes the text of one memory (used by the Memory screen).
  Future<MemoryResult> edit(String id, String newText) async {
    final clean = newText.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (clean.length < 3 || clean.length > maxLength) {
      return const MemoryResult(
        MemoryStatus.invalid,
        'A memory must be between 3 and 300 characters.',
      );
    }
    if (looksSecret(clean)) {
      return const MemoryResult(
        MemoryStatus.rejectedSecret,
        'I never store passwords, PINs, card or ID numbers, or API keys.',
      );
    }
    final items = await _load();
    final i = items.indexWhere((m) => m.id == id);
    if (i < 0) {
      return const MemoryResult(MemoryStatus.invalid, 'That memory no longer exists.');
    }
    items[i].text = clean;
    items[i].updatedAt = DateTime.now();
    await _save();
    return MemoryResult(MemoryStatus.updated, 'Memory updated.', items[i]);
  }

  Future<bool> delete(String id) async {
    final items = await _load();
    final before = items.length;
    items.removeWhere((m) => m.id == id);
    if (items.length == before) return false;
    await _save();
    return true;
  }

  Future<void> clearAll() async {
    final items = await _load();
    items.clear();
    await _save();
  }

  /// A short block of the memories most relevant to [message], to add to the
  /// AI's instructions. Returns an empty string when nothing is relevant.
  Future<String> contextFor(String message, {int limit = 5}) async {
    try {
      final items = await _load();
      if (items.isEmpty) return '';
      final words = _tokens(message);
      final lowerMessage = message.toLowerCase();
      final scored = <MapEntry<MemoryItem, int>>[];
      for (final item in items) {
        var score = 0;
        for (final w in _tokens(item.text)) {
          if (words.contains(w)) score += 2;
        }
        final project = item.project;
        if (project != null &&
            project.isNotEmpty &&
            lowerMessage.contains(project.toLowerCase())) {
          score += 4;
        }
        if (item.kind == 'preference') score += 1;
        if (score > 0) scored.add(MapEntry(item, score));
      }
      if (scored.isEmpty) return '';
      scored.sort((a, b) => b.value.compareTo(a.value));
      final buffer = StringBuffer(
        'Things the user asked you to remember (use them only when relevant '
        'and do not list them unprompted):\n',
      );
      for (final entry in scored.take(limit)) {
        final item = entry.key;
        final project = item.project;
        buffer.writeln(
          project != null ? '- [project $project] ${item.text}' : '- ${item.text}',
        );
      }
      return buffer.toString().trim();
    } catch (_) {
      return '';
    }
  }
}
