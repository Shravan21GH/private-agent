import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One quick note.
class ZaxNote {
  final String id;
  String text;
  final DateTime createdAt;

  ZaxNote({required this.id, required this.text, required this.createdAt});

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
  };

  static ZaxNote? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final text = raw['text'];
    final created = DateTime.tryParse('${raw['createdAt']}');
    if (id is! String || text is! String || created == null) return null;
    return ZaxNote(id: id, text: text, createdAt: created);
  }
}

/// Notes live inside the app (saved on the phone). Newest first.
class NotesStore {
  NotesStore._();
  static final NotesStore instance = NotesStore._();

  static const String _key = 'zax_notes_v1';
  static const int maxNotes = 500;

  List<ZaxNote>? _items;

  Future<List<ZaxNote>> _load() async {
    final cached = _items;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    final list = <ZaxNote>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            final note = ZaxNote.fromJson(item);
            if (note != null) list.add(note);
          }
        }
      } catch (_) {
        // A damaged list starts again empty instead of crashing the app.
      }
    }
    _items = list;
    return list;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _items ?? <ZaxNote>[];
    await prefs.setString(
      _key,
      jsonEncode(list.map((n) => n.toJson()).toList()),
    );
  }

  Future<List<ZaxNote>> all() async => List<ZaxNote>.from(await _load());

  Future<int> count() async => (await _load()).length;

  Future<ZaxNote?> add(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return null;
    final list = await _load();
    if (list.length >= maxNotes) return null;
    final now = DateTime.now();
    final note = ZaxNote(
      id: now.microsecondsSinceEpoch.toString(),
      text: clean,
      createdAt: now,
    );
    list.insert(0, note);
    await _save();
    return note;
  }

  Future<bool> edit(String id, String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return false;
    final list = await _load();
    final index = list.indexWhere((n) => n.id == id);
    if (index < 0) return false;
    list[index].text = clean;
    await _save();
    return true;
  }

  Future<bool> delete(String id) async {
    final list = await _load();
    final before = list.length;
    list.removeWhere((n) => n.id == id);
    if (list.length == before) return false;
    await _save();
    return true;
  }

  Future<List<ZaxNote>> search(String query) async {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 1)
        .toList();
    if (words.isEmpty) return [];
    final list = await _load();
    return list.where((n) {
      final lower = n.text.toLowerCase();
      return words.every(lower.contains);
    }).toList();
  }
}

/// Files that Zax creates for you ("create a file called ideas.txt with ...").
/// They are saved in a private folder of the app and can be shared from the
/// Notes & Files screen.
class ZaxFiles {
  ZaxFiles._();
  static final ZaxFiles instance = ZaxFiles._();

  static const int maxBytes = 500000;

  Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/zax_files');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// A safe file name: letters, numbers, dot, dash, underscore and space only.
  static String safeName(String raw) {
    var name = raw.trim().replaceAll(RegExp(r'[\\/]+'), '_');
    name = name.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '');
    name = name.replaceAll(RegExp(r'^\.+'), '').trim();
    if (name.isEmpty) name = 'zax_file';
    if (name.length > 60) name = name.substring(0, 60);
    if (!name.contains('.')) name = '$name.txt';
    return name;
  }

  /// Creates a file and returns its final name, or null when the content is
  /// empty or too big. An existing file is never overwritten.
  Future<String?> create(String rawName, String content) async {
    if (content.trim().isEmpty) return null;
    if (utf8.encode(content).length > maxBytes) return null;
    final dir = await _dir();
    final name = safeName(rawName);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var candidate = name;
    var n = 2;
    while (await File('${dir.path}/$candidate').exists()) {
      candidate = '${stem}_$n$ext';
      n++;
      if (n > 200) return null;
    }
    await File('${dir.path}/$candidate').writeAsString(content);
    return candidate;
  }

  Future<List<File>> list() async {
    final dir = await _dir();
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File) files.add(entity);
    }
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  Future<String> read(File file) async {
    try {
      return await file.readAsString();
    } catch (_) {
      return '(This file could not be read as text.)';
    }
  }

  Future<void> delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
