import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// A problem with a file or folder operation, with a message fit to show.
class FileStoreException implements Exception {
  final String message;
  FileStoreException(this.message);

  @override
  String toString() => message;
}

/// One folder or file in Zax's own file space.
class ZaxEntry {
  final String name;
  final bool isFolder;
  final int size;
  final DateTime modified;

  const ZaxEntry(this.name, this.isFolder, this.size, this.modified);
}

class ZaxSearchHit {
  final String folder;
  final String file;
  final String snippet;

  const ZaxSearchHit(this.folder, this.file, this.snippet);
}

/// Real folders and text files that live inside Zax's private app storage
/// (nothing else on the phone is touched, and no storage permission is
/// needed). Every name is cleaned so it cannot point outside this space.
class ProjectFileStore {
  ProjectFileStore({Directory? root}) : _root = root;

  static final ProjectFileStore instance = ProjectFileStore();

  /// Shown to the user as the top folder.
  static const String displayRoot = 'Zax Files';
  static const int maxFileBytes = 1024 * 1024;
  static const Set<String> allowedExtensions = {
    'txt', 'md', 'json', 'csv', 'lua', 'luau', 'py', 'dart', 'js', 'ts',
    'html', 'css', 'xml', 'yaml', 'yml', 'kt', 'java', 'cs', 'cpp', 'c',
  };

  Directory? _root;

  Future<Directory> _rootDir() async {
    var root = _root;
    if (root == null) {
      final docs = await getApplicationDocumentsDirectory();
      root = Directory('${docs.path}/$displayRoot');
      _root = root;
    }
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }

  // ───────────────────────── Names ─────────────────────────

  /// Turns any text into a safe single file or folder name.
  static String sanitizeName(String raw, {String fallback = 'Untitled'}) {
    var s = raw.replaceAll(RegExp(r'[\u0000-\u001F<>:"/\\|?*]'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceAll(RegExp(r'^[.\s]+'), '').replaceAll(RegExp(r'[.\s]+$'), '');
    if (s.length > 60) s = s.substring(0, 60).trim();
    return s.isEmpty ? fallback : s;
  }

  /// A safe file name that always ends in an allowed text extension.
  static String fileNameFor(String raw, {String fallback = 'Notes'}) {
    final s = sanitizeName(raw, fallback: fallback);
    final dot = s.lastIndexOf('.');
    if (dot > 0 && allowedExtensions.contains(s.substring(dot + 1).toLowerCase())) {
      return s;
    }
    return '$s.txt';
  }

  /// Rejects names that were not produced by this store (for example "..").
  static void _checkExistingName(String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000')) {
      throw FileStoreException('That name is not allowed.');
    }
  }

  Future<String> _uniqueName(Directory parent, String base, {required bool isFile}) async {
    var stem = base;
    var ext = '';
    if (isFile) {
      final dot = base.lastIndexOf('.');
      if (dot > 0) {
        stem = base.substring(0, dot);
        ext = base.substring(dot);
      }
    }
    var candidate = base;
    var n = 2;
    while (await FileSystemEntity.type('${parent.path}/$candidate') !=
        FileSystemEntityType.notFound) {
      candidate = '$stem ($n)$ext';
      n++;
      if (n > 500) throw FileStoreException('Too many items have that name.');
    }
    return candidate;
  }

  Future<Directory> _folderDir(String folder) async {
    _checkExistingName(folder);
    final root = await _rootDir();
    final dir = Directory('${root.path}/$folder');
    if (!await dir.exists()) {
      throw FileStoreException('The folder "$folder" does not exist.');
    }
    return dir;
  }

  Future<File> _file(String folder, String name) async {
    _checkExistingName(name);
    final dir = await _folderDir(folder);
    final file = File('${dir.path}/$name');
    if (!await file.exists()) {
      throw FileStoreException('The file "$name" does not exist.');
    }
    return file;
  }

  // ───────────────────────── Folders ─────────────────────────

  /// Creates a folder and returns its real name (a number is added if a
  /// folder with that name already exists).
  Future<String> createFolder(String name) async {
    final root = await _rootDir();
    final unique = await _uniqueName(root, sanitizeName(name), isFile: false);
    await Directory('${root.path}/$unique').create();
    return unique;
  }

  /// Uses the folder if it exists, otherwise creates it.
  Future<String> ensureFolder(String name) async {
    final root = await _rootDir();
    final clean = sanitizeName(name);
    final dir = Directory('${root.path}/$clean');
    if (await dir.exists()) return clean;
    await dir.create();
    return clean;
  }

  Future<bool> folderExists(String name) async {
    final root = await _rootDir();
    return Directory('${root.path}/${sanitizeName(name)}').exists();
  }

  Future<void> renameFolder(String oldName, String newName) async {
    final dir = await _folderDir(oldName);
    final root = await _rootDir();
    final clean = sanitizeName(newName);
    if (clean == oldName) return;
    if (await FileSystemEntity.type('${root.path}/$clean') != FileSystemEntityType.notFound) {
      throw FileStoreException('A folder named "$clean" already exists.');
    }
    await dir.rename('${root.path}/$clean');
  }

  Future<void> deleteFolder(String name) async {
    final dir = await _folderDir(name);
    await dir.delete(recursive: true);
  }

  // ───────────────────────── Files ─────────────────────────

  /// Folders (when [folder] is null) or the files inside a folder.
  Future<List<ZaxEntry>> list(String? folder) async {
    final Directory dir = folder == null ? await _rootDir() : await _folderDir(folder);
    final entries = <ZaxEntry>[];
    await for (final e in dir.list(followLinks: false)) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name.endsWith('.tmp')) continue;
      final stat = await e.stat();
      if (folder == null && e is Directory) {
        entries.add(ZaxEntry(name, true, 0, stat.modified));
      } else if (folder != null && e is File) {
        entries.add(ZaxEntry(name, false, stat.size, stat.modified));
      }
    }
    entries.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return entries;
  }

  Future<int> fileCount(String folder) async => (await list(folder)).length;

  /// Saves a file and returns its real name (a number is added if needed).
  Future<String> createFile(String folder, String name, String content) async {
    if (utf8.encode(content).length > maxFileBytes) {
      throw FileStoreException('That is too big for one file (1 MB at most).');
    }
    final dir = await _folderDir(folder);
    final unique = await _uniqueName(dir, fileNameFor(name), isFile: true);
    await _writeAtomically(File('${dir.path}/$unique'), content);
    return unique;
  }

  Future<String> readFile(String folder, String name) async {
    final file = await _file(folder, name);
    if (await file.length() > maxFileBytes) {
      throw FileStoreException('That file is too big to open here.');
    }
    try {
      return await file.readAsString();
    } on FormatException {
      throw FileStoreException('That file is not plain text.');
    }
  }

  Future<void> writeFile(String folder, String name, String content) async {
    if (utf8.encode(content).length > maxFileBytes) {
      throw FileStoreException('That is too big for one file (1 MB at most).');
    }
    final file = await _file(folder, name);
    await _writeAtomically(file, content);
  }

  Future<String> renameFile(String folder, String oldName, String newName) async {
    final file = await _file(folder, oldName);
    final dir = await _folderDir(folder);
    final clean = fileNameFor(newName);
    if (clean == oldName) return oldName;
    if (await FileSystemEntity.type('${dir.path}/$clean') != FileSystemEntityType.notFound) {
      throw FileStoreException('A file named "$clean" already exists.');
    }
    await file.rename('${dir.path}/$clean');
    return clean;
  }

  Future<void> deleteFile(String folder, String name) async {
    final file = await _file(folder, name);
    await file.delete();
  }

  Future<void> _writeAtomically(File target, String content) async {
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(content, flush: true);
    await temp.rename(target.path);
  }

  // ───────────────────────── Search ─────────────────────────

  /// Looks in file names and file contents.
  Future<List<ZaxSearchHit>> search(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    final hits = <ZaxSearchHit>[];
    for (final folder in await list(null)) {
      for (final file in await list(folder.name)) {
        if (hits.length >= 50) return hits;
        if (file.name.toLowerCase().contains(q)) {
          hits.add(ZaxSearchHit(folder.name, file.name, ''));
          continue;
        }
        if (file.size > maxFileBytes) continue;
        try {
          final text = await readFile(folder.name, file.name);
          final i = text.toLowerCase().indexOf(q);
          if (i >= 0) {
            final start = i > 30 ? i - 30 : 0;
            final end = i + q.length + 50 < text.length ? i + q.length + 50 : text.length;
            hits.add(ZaxSearchHit(
              folder.name,
              file.name,
              text.substring(start, end).replaceAll(RegExp(r'\s+'), ' '),
            ));
          }
        } catch (_) {
          // Unreadable file: skip it.
        }
      }
    }
    return hits;
  }
}
