import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import '../models/agent_action.dart';
import 'action_handler.dart';
import 'ai_service.dart';
import 'chat_recall.dart';
import 'instant_commands.dart';
import 'memory_store.dart';
import 'notes_store.dart';
import 'task_store.dart';
import 'vision_service.dart';

/// What the fast router answers with.
class FastReply {
  final String text;

  /// A photo to show above the text (path of a file on the phone).
  final String? imagePath;

  const FastReply(this.text, {this.imagePath});
}

/// Handles clear commands on the phone itself, WITHOUT a round trip to the AI.
/// This is what makes "open Discord", "set a timer", "make a note" and
/// "take a photo" feel instant. Anything it does not clearly recognise
/// returns null, and the message then goes to the AI as usual.
class ZaxFastRouter {
  ZaxFastRouter({required this.actionHandler, required this.aiService});

  final ActionHandler actionHandler;
  final AiService aiService;

  static const String _ownPackage = 'com.orailnoor.privateagent';

  static final RegExp _prefix = RegExp(
    r'^(?:please\s+)?(?:(?:hey|ok)\s+)?(?:zax[,\s]+)?(?:please\s+)?',
    caseSensitive: false,
  );

  // ───────────── camera ─────────────
  static final RegExp _takePhoto = RegExp(
    r'^(?:take|snap|capture|click|shoot)\s+(?:me\s+)?(?:a\s+|an\s+|the\s+)?'
    r'(?:new\s+)?(?:photo|picture|pic|selfie|snap)\b(.*)$',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _lookAt = RegExp(
    r"^(?:look\s+at\s+(?:this|that|it)|(?:what|who)(?:'s|\s+is)\s+(?:this|that)"
    r'(?:\s+(?:thing|object|plant|flower|animal|food|bug|insect|person|building))?'
    r'|what\s+do\s+you\s+see|what\s+am\s+i\s+(?:looking\s+at|holding)'
    r'|scan\s+(?:this|that)|identify\s+(?:this|that)'
    r'|describe\s+(?:this|that|what\s+you\s+see)|can\s+you\s+see\s+(?:this|that)'
    r'|read\s+(?:this|that)\s+(?:text|page|sign|label|menu|note|paper)'
    r'|use\s+(?:the\s+|your\s+)?camera)(?:\s+(?:for\s+me|please))?$',
    caseSensitive: false,
  );

  static final RegExp _openCameraAnd = RegExp(
    r'^(?:open|start|use)\s+(?:the\s+|your\s+)?camera\s+(?:and|to)\s+(.+)$',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _analyseWords = RegExp(
    r'\b(?:and|then|to)\s+(?:tell|describe|what|read|identify|explain|say|translate)\b',
    caseSensitive: false,
  );

  // ───────────── notes and files ─────────────
  static final RegExp _addNote = RegExp(
    r'^(?:please\s+)?(?:(?:make|take|write|add|save|create|jot\s+down|put\s+down)'
    r'\s+(?:me\s+)?(?:a\s+|an\s+|this\s+|a\s+new\s+)?note\b|note\s+down\b|note\b)'
    r'\s*(?:to\s+self|that|saying|says)?\s*[:,\-]?\s*(.+)$',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _listNotes = RegExp(
    r'^(?:show|list|open|see|read|display)\s+(?:me\s+)?(?:all\s+)?(?:my\s+)?notes$',
    caseSensitive: false,
  );

  static final RegExp _deleteNote = RegExp(
    r'^(?:delete|remove)\s+(?:my\s+)?note\s+(?:number\s+|no\.?\s*|#)?(\d{1,3})$',
    caseSensitive: false,
  );

  static final RegExp _findNotes = RegExp(
    r'^(?:find|search)\s+(?:my\s+)?notes?\s+(?:for|about|on)\s+(.+)$',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _createFile = RegExp(
    r'^(?:please\s+)?(?:create|make|write|save)\s+(?:me\s+)?(?:a\s+|an\s+)?(?:new\s+)?'
    r'(?:text\s+|txt\s+|markdown\s+|md\s+)?file\s+(?:called|named)\s+(\S+?)\s*'
    r'(?:with|containing|that\s+says|saying|:)\s*(.+)$',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _listFiles = RegExp(
    r'^(?:show|list)\s+(?:me\s+)?(?:all\s+)?(?:my\s+)?(?:zax\s+)?files$',
    caseSensitive: false,
  );

  // ───────────── briefing ─────────────
  static final RegExp _briefing = RegExp(
    r"^(?:good\s+(?:morning|afternoon|evening)(?:\s+zax)?|(?:give\s+me\s+)?(?:my\s+)?"
    r'(?:daily\s+)?(?:briefing|brief\s+me|rundown)'
    r"|what(?:'s|\s+is)\s+(?:my\s+day|on\s+today|the\s+plan\s+for\s+today|my\s+plan\s+for\s+today)"
    r'|start\s+my\s+day)$',
    caseSensitive: false,
  );

  // ───────────── open an app, then read it ─────────────
  static final RegExp _openAndRead = RegExp(
    r'^(?:open|go\s+to|launch|start)\s+(.+?)\s+(?:and|then)\s+'
    r'((?:read|check|tell|summari[sz]e|see|show|what|whats|list|look)\b.*)$',
    caseSensitive: false,
    dotAll: true,
  );

  /// Returns a reply when Zax handled the message itself, or null to send it
  /// to the AI.
  Future<FastReply?> tryHandle(
    String input, {
    void Function(String message)? onStatus,
  }) async {
    var text = input.trim();
    if (text.isEmpty) return null;
    text = text.replaceFirst(_prefix, '').trim();
    if (text.isEmpty) return null;
    final clean = text.replaceAll(RegExp(r'[.!?]+$'), '').trim();
    final lower = clean.toLowerCase();

    final camera = await _camera(clean, lower, onStatus);
    if (camera != null) return camera;

    final history = await ChatRecall.answerHistoryQuestion(clean, lower);
    if (history != null) return FastReply(history);

    final notes = await _notesAndFiles(clean, lower);
    if (notes != null) return notes;

    if (_briefing.hasMatch(lower)) return FastReply(await _briefingText());

    final read = _openAndRead.firstMatch(clean);
    if (read != null) {
      return _openAndReadApp(
        read.group(1)!.trim(),
        read.group(2)!.trim(),
        onStatus,
      );
    }

    // Tasks, goals, reminders, memory, projects, routines and "open <app>".
    final quick = await actionHandler.runQuickCommand(input);
    if (quick != null) return FastReply(quick);

    return _instant(text, lower);
  }

  // ───────────────────────── camera ─────────────────────────

  Future<FastReply?> _camera(
    String clean,
    String lower,
    void Function(String)? onStatus,
  ) async {
    String? question;
    var analyse = false;

    final photo = _takePhoto.firstMatch(clean);
    final openAnd = _openCameraAnd.firstMatch(clean);
    if (photo != null) {
      final rest = (photo.group(1) ?? '').trim();
      if (rest.isNotEmpty && _analyseWords.hasMatch(rest)) {
        analyse = true;
        question = rest.replaceFirst(RegExp(r'^(?:and|then|to)\s+', caseSensitive: false), '');
      }
    } else if (_lookAt.hasMatch(lower)) {
      analyse = true;
      question = lower == 'use the camera' || lower == 'use camera' || lower == 'use your camera'
          ? 'Describe what you see.'
          : clean;
    } else if (openAnd != null) {
      analyse = true;
      question = openAnd.group(1)!.trim();
    } else {
      return null;
    }

    try {
      onStatus?.call('Opening the camera...');
      final file = await _capture();
      if (file == null) return const FastReply('No photo was taken.');
      if (!analyse) {
        return FastReply(
          'Here is your photo. Next time say "what is this" and I will tell you what is in it.',
          imagePath: file.path,
        );
      }
      onStatus?.call('Looking at it...');
      final answer = await VisionService.describe(
        ai: aiService,
        image: file,
        question: question ?? 'Describe what you see.',
      );
      return FastReply(answer, imagePath: file.path);
    } catch (e) {
      return FastReply(
        'I could not do that with the camera: ${e.toString().replaceFirst('Exception: ', '')}',
      );
    }
  }

  Future<File?> _capture() async {
    final picker = ImagePicker();
    final XFile? shot = await picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1280,
      imageQuality: 80,
    );
    if (shot == null) return null;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/zax_photos');
    if (!await dir.exists()) await dir.create(recursive: true);
    final saved = File(
      '${dir.path}/photo_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await File(shot.path).copy(saved.path);
    return saved;
  }

  // ───────────────────── notes and files ─────────────────────

  Future<FastReply?> _notesAndFiles(String clean, String lower) async {
    final store = NotesStore.instance;

    if (_listNotes.hasMatch(lower)) {
      final notes = await store.all();
      if (notes.isEmpty) {
        return const FastReply('You have no notes yet. Say "make a note: ..." to add one.');
      }
      final buffer = StringBuffer('Your notes (newest first):\n');
      var i = 1;
      for (final n in notes.take(15)) {
        final when = DateFormat('d MMM').format(n.createdAt);
        buffer.writeln('$i. ${_oneLine(n.text, 110)}  ($when)');
        i++;
      }
      if (notes.length > 15) {
        buffer.writeln('...and ${notes.length - 15} more in Notes & Files.');
      }
      buffer.write('\nSay "delete note 2" to remove one.');
      return FastReply(buffer.toString());
    }

    final del = _deleteNote.firstMatch(lower);
    if (del != null) {
      final number = int.parse(del.group(1)!);
      final notes = await store.all();
      if (number < 1 || number > notes.length) {
        return FastReply('I do not have a note number $number. Say "show my notes" to see them.');
      }
      final target = notes[number - 1];
      final ok = await store.delete(target.id);
      return FastReply(
        ok
            ? 'Deleted note $number: "${_oneLine(target.text, 60)}".'
            : 'I could not delete that note.',
      );
    }

    final find = _findNotes.firstMatch(clean);
    if (find != null) {
      final query = find.group(1)!.trim();
      final hits = await store.search(query);
      if (hits.isEmpty) return FastReply('No notes match "$query".');
      final buffer = StringBuffer('Notes matching "$query":\n');
      for (final n in hits.take(8)) {
        buffer.writeln('• ${_oneLine(n.text, 110)}');
      }
      return FastReply(buffer.toString().trim());
    }

    final file = _createFile.firstMatch(clean);
    if (file != null) {
      final name = file.group(1)!.trim();
      final content = file.group(2)!.trim();
      final saved = await ZaxFiles.instance.create(name, content);
      if (saved == null) {
        return const FastReply(
          'I could not create that file. It needs some content and must be under 500 KB.',
        );
      }
      return FastReply(
        'Created "$saved". Open Notes & Files from the menu to read it or share it.',
      );
    }

    if (_listFiles.hasMatch(lower)) {
      final files = await ZaxFiles.instance.list();
      if (files.isEmpty) {
        return const FastReply(
          'No files yet. Say "create a file called ideas.txt with ..." to make one.',
        );
      }
      final buffer = StringBuffer('Your files:\n');
      for (final f in files.take(15)) {
        buffer.writeln('• ${f.uri.pathSegments.last}');
      }
      return FastReply(buffer.toString().trim());
    }

    final add = _addNote.firstMatch(clean);
    if (add != null) {
      final saved = await store.add(add.group(1)!.trim());
      if (saved == null) {
        return const FastReply('I could not save that note (it was empty or the notes list is full).');
      }
      final count = await store.count();
      return FastReply(
        'Noted. 📝 You now have $count note${count == 1 ? '' : 's'}. '
        'Say "show my notes" any time.',
      );
    }
    return null;
  }

  static String _oneLine(String text, int max) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max - 3)}...';
  }

  // ───────────────────────── briefing ─────────────────────────

  Future<String> _briefingText() async {
    final now = DateTime.now();
    final hello = now.hour < 12
        ? 'Good morning'
        : (now.hour < 17 ? 'Good afternoon' : 'Good evening');
    final buffer = StringBuffer(
      '$hello! It is ${DateFormat('EEEE, d MMMM').format(now)}, '
      '${DateFormat('h:mm a').format(now)}.\n\n',
    );

    final tasks = await TaskStore.instance.pending();
    final overdue = tasks.where((t) => t.isOverdue(now)).toList();
    final today = tasks.where((t) {
      final due = t.dueDate;
      return due != null &&
          !t.isOverdue(now) &&
          due.year == now.year &&
          due.month == now.month &&
          due.day == now.day;
    }).toList();

    if (tasks.isEmpty) {
      buffer.writeln('✅ No pending tasks. Nice and clear.');
    } else {
      buffer.writeln(
        '✅ ${tasks.length} pending task${tasks.length == 1 ? '' : 's'}'
        '${overdue.isEmpty ? '' : ', ${overdue.length} overdue'}.',
      );
      for (final t in overdue.take(3)) {
        buffer.writeln('   ⚠️ ${_oneLine(t.title, 60)} (overdue)');
      }
      for (final t in today.take(4)) {
        buffer.writeln('   • ${_oneLine(t.title, 60)} (today)');
      }
      if (overdue.isEmpty && today.isEmpty) {
        for (final t in tasks.take(3)) {
          buffer.writeln('   • ${_oneLine(t.title, 60)}');
        }
      }
    }

    final notes = await NotesStore.instance.count();
    final memories = (await MemoryStore.instance.items()).length;
    buffer.writeln('\n📝 $notes note${notes == 1 ? '' : 's'} saved.');
    buffer.writeln('🧠 $memories thing${memories == 1 ? '' : 's'} in my memory.');
    buffer.write('\nWhat are we doing first?');
    return buffer.toString();
  }

  // ─────────────────── open an app and read it ───────────────────

  Future<FastReply> _openAndReadApp(
    String app,
    String request,
    void Function(String)? onStatus,
  ) async {
    final screen = actionHandler.screenAutomation;
    final launcher = actionHandler.launcher;

    onStatus?.call('Opening $app...');
    final opened = await launcher.openApp(app);
    if (!opened.startsWith('Opened')) return FastReply(opened);

    if (!await screen.isServiceRunning()) {
      return FastReply(
        '$opened. I cannot read the screen yet, because Zax Screen Control '
        'is switched off. Turn it on in Android Settings > Accessibility, '
        'then ask me again.',
      );
    }
    if (!aiService.isConfigured) {
      return FastReply('$opened, but no AI provider is set up to read it for you.');
    }

    // Wait until the app has really drawn something readable.
    onStatus?.call('Reading the screen...');
    var description = '';
    for (int i = 0; i < 7; i++) {
      await Future.delayed(Duration(milliseconds: i == 0 ? 900 : 450));
      description = await screen.getScreenDescription();
      final readable =
          !description.startsWith('Could not read screen') &&
          description.length > 350 &&
          !description.contains(_ownPackage);
      if (readable) break;
    }
    if (description.startsWith('Could not read screen')) {
      return FastReply('$opened, but I could not read what is on the screen.');
    }
    if (description.length > 7000) description = description.substring(0, 7000);

    // Bring Zax back to the front while the AI works on the answer.
    try {
      await launcher.openPackage(_ownPackage);
    } catch (_) {}

    try {
      onStatus?.call('Thinking...');
      final reply = await aiService.sendTaskMessage(
        'You are Zax, the user\'s friendly personal assistant. You are given a '
        'text dump of what is currently visible on the user\'s phone screen. '
        'Answer the user\'s request using ONLY that text. Be concise, warm and '
        'natural. If only part of a conversation or list is visible, say that '
        'you can only see what was on screen. Never invent messages or details.',
        'User request: $request\nApp: $app\n\nScreen text:\n$description',
      );
      final answer = reply.content.trim();
      if (answer.isEmpty) return FastReply('I read the screen but could not make sense of it.');
      return FastReply(answer);
    } catch (e) {
      return FastReply(
        'I opened $app and read the screen, but the AI could not answer: '
        '${e.toString().replaceFirst('Exception: ', '')}',
      );
    }
  }

  // ───────────────────── instant commands ─────────────────────

  Future<FastReply?> _instant(String text, String lower) async {
    final cmd = InstantCommand.parse(text);
    if (cmd == null) return null;

    switch (cmd.type) {
      case InstantType.time:
        final now = DateTime.now();
        return FastReply(
          'It is ${DateFormat('h:mm a').format(now)} on '
          '${DateFormat('EEEE, d MMMM y').format(now)}.',
        );
      case InstantType.timer:
        return _run('set_timer', {'seconds': cmd.number, 'label': 'Zax timer'});
      case InstantType.alarm:
        return _run('set_alarm', {
          'hour': cmd.number,
          'minute': cmd.minute,
          'label': 'Zax alarm',
        });
      case InstantType.volume:
        return _run('set_volume', {'level': cmd.number});
      case InstantType.brightness:
        return _run('set_brightness', {'level': cmd.number});
      case InstantType.call:
        return _run('make_call', {'contact_name': cmd.text});
      case InstantType.website:
        return _run('open_url', {'url': cmd.text});
      case InstantType.youtubeSearch:
        return _run('open_url', {
          'url':
              'https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(cmd.text)}',
        });
      case InstantType.mapsSearch:
        return _run('open_url', {
          'url':
              'https://www.google.com/maps/search/?api=1&query=${Uri.encodeQueryComponent(cmd.text)}',
        });
      case InstantType.googleSearch:
        // Only when the user clearly said "google ..." so normal questions
        // still get a real answer from the AI.
        if (!(lower.startsWith('google ') || lower.contains(' on google'))) {
          return null;
        }
        return _run('open_url', {
          'url':
              'https://www.google.com/search?q=${Uri.encodeQueryComponent(cmd.text)}',
        });
    }
  }

  Future<FastReply> _run(String action, Map<String, dynamic> params) async {
    final result = await actionHandler.execute(
      AgentAction(action: action, params: params, response: ''),
    );
    final details =
        result.details ?? (result.success ? 'Done.' : 'That did not work.');
    return FastReply(result.success ? details : '⚠️ $details');
  }
}
