import 'package:intl/intl.dart';
import 'chat_history_service.dart';
import 'memory_store.dart';

/// Lets Zax look back through ALL your saved chats (not only the one that is
/// open) so it can remember what you talked about before.
///
/// Two things use it:
///  * [contextFor] quietly adds a few relevant lines from older chats to the
///    AI's instructions before it answers.
///  * [answerHistoryQuestion] answers questions such as "what did we talk
///    about yesterday?" or "search my chats for pizza" on the phone itself.
class ChatRecall {
  ChatRecall._();

  /// The chat that is open right now (set by the home screen). Its messages
  /// are already in the conversation, so they are skipped when searching.
  static String currentSessionId = '';

  static List<ChatSession>? _cache;
  static DateTime? _cachedAt;

  static const Set<String> _stop = {
    'the', 'and', 'for', 'are', 'but', 'not', 'you', 'all', 'can', 'her',
    'was', 'one', 'our', 'out', 'has', 'have', 'had', 'his', 'how', 'its',
    'let', 'may', 'new', 'now', 'old', 'see', 'two', 'way', 'who', 'did',
    'does', 'what', 'when', 'where', 'which', 'with', 'this', 'that', 'then',
    'than', 'they', 'them', 'there', 'about', 'would', 'could', 'should',
    'your', 'from', 'into', 'just', 'like', 'will', 'some', 'tell', 'please',
    'zax', 'hey', 'hello', 'make', 'want', 'need', 'give', 'show', 'know',
  };

  static Set<String> _words(String text) {
    final parts = text.toLowerCase().split(RegExp(r'[^\p{L}\p{N}]+', unicode: true));
    return parts.where((w) => w.length > 2 && !_stop.contains(w)).toSet();
  }

  static Future<List<ChatSession>> _sessions() async {
    final now = DateTime.now();
    final at = _cachedAt;
    final cached = _cache;
    if (cached != null && at != null && now.difference(at).inSeconds < 20) {
      return cached;
    }
    final loaded = await ChatHistoryService.loadSessions();
    _cache = loaded;
    _cachedAt = now;
    return loaded;
  }

  /// Forget the cached chats so the next search reads the file again.
  static void refresh() {
    _cachedAt = null;
  }

  static String _clip(String text, int max) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max - 3)}...';
  }

  static String _day(DateTime when) => DateFormat('EEE d MMM').format(when);

  /// A short block of lines from OLDER chats that look relevant to [message],
  /// or an empty string. Passwords, keys and similar are never included.
  static Future<String> contextFor(String message, {int limit = 3}) async {
    try {
      final words = _words(message);
      if (words.isEmpty) return '';
      final needed = words.length >= 2 ? 2 : 1;
      final sessions = await _sessions();
      final found = <MapEntry<String, int>>[];

      for (final session in sessions) {
        if (session.id == currentSessionId) continue;
        for (final raw in session.messages) {
          final role = raw['role'];
          final content = raw['content'];
          if (role is! String || content is! String) continue;
          if (content.length > 1500 || content.startsWith('⏳')) continue;
          if (MemoryStore.looksSecret(content)) continue;
          var score = 0;
          for (final w in _words(content)) {
            if (words.contains(w)) score++;
          }
          if (score >= needed) {
            final who = role == 'user' ? 'user' : 'zax';
            found.add(
              MapEntry(
                '[${_day(session.timestamp)}, chat "${_clip(session.title, 30)}"] '
                '$who: ${_clip(content, 220)}',
                score,
              ),
            );
          }
        }
      }
      if (found.isEmpty) return '';
      found.sort((a, b) => b.value.compareTo(a.value));
      final buffer = StringBuffer(
        'Lines from the user\'s EARLIER chats that may be relevant (use them '
        'only if they help, and do not read them out unprompted):\n',
      );
      var used = 0;
      for (final entry in found.take(limit)) {
        if (used + entry.key.length > 900) break;
        buffer.writeln('- ${entry.key}');
        used += entry.key.length;
      }
      return buffer.toString().trim();
    } catch (_) {
      return '';
    }
  }

  static final RegExp _timeQuestion = RegExp(
    r'\b(?:what|which|remind\s+me\s+what)\b.*\b(?:we|i)\b.*'
    r'\b(?:talk|talked|chat|chatted|discuss|discussed|spoke|said)\b',
    caseSensitive: false,
  );

  static final RegExp _searchChats = RegExp(
    r'^(?:please\s+)?(?:search|find|look\s+up|look\s+through)\s+'
    r'(?:in\s+)?(?:my\s+|all\s+|our\s+)?(?:old\s+|past\s+)?'
    r'(?:chats?|conversations?|history)\s+(?:for|about)\s+(.+)$',
    caseSensitive: false,
    dotAll: true,
  );

  /// Handles "what did we talk about ..." and "search my chats for ...".
  /// Returns null when [lower] is not one of those questions.
  static Future<String?> answerHistoryQuestion(String clean, String lower) async {
    final search = _searchChats.firstMatch(clean);
    if (search != null) return _searchAnswer(search.group(1)!.trim());
    if (!_timeQuestion.hasMatch(lower)) return null;
    if (!RegExp(
      r'\b(?:yesterday|today|earlier|before|last\s+time|last\s+night|recently|previously)\b',
    ).hasMatch(lower)) {
      return null;
    }

    final sessions = await _sessions();
    final others = sessions.where((s) => s.id != currentSessionId).toList();
    if (others.isEmpty) {
      return 'I do not have any older chats saved yet, so there is nothing to look back on.';
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    List<ChatSession> picked;
    String label;
    if (lower.contains('yesterday')) {
      final start = today.subtract(const Duration(days: 1));
      picked = others
          .where((s) => !s.timestamp.isBefore(start) && s.timestamp.isBefore(today))
          .toList();
      label = 'yesterday';
    } else if (lower.contains('today') || lower.contains('earlier')) {
      picked = others.where((s) => !s.timestamp.isBefore(today)).toList();
      label = 'earlier today';
    } else {
      picked = others.take(5).toList();
      label = 'recently';
    }
    if (picked.isEmpty) {
      return 'I do not see any saved chats from $label.';
    }

    final buffer = StringBuffer('Here is what we talked about $label:\n');
    for (final session in picked.take(6)) {
      String first = '';
      for (final raw in session.messages) {
        final content = raw['content'];
        if (raw['role'] == 'user' && content is String && content.trim().isNotEmpty) {
          first = _clip(content, 90);
          break;
        }
      }
      final when = DateFormat('EEE d MMM, h:mm a').format(session.timestamp);
      buffer.writeln(
        '• $when - ${_clip(session.title, 40)}${first.isEmpty ? '' : ': "$first"'}',
      );
    }
    buffer.write('\nOpen the menu to reopen any of these chats.');
    return buffer.toString();
  }

  static Future<String> _searchAnswer(String query) async {
    final words = _words(query);
    if (words.isEmpty) return 'What should I search for in your chats?';
    final sessions = await _sessions();
    final hits = <MapEntry<String, int>>[];
    for (final session in sessions) {
      for (final raw in session.messages) {
        final content = raw['content'];
        if (content is! String || content.startsWith('⏳')) continue;
        if (MemoryStore.looksSecret(content)) continue;
        var score = 0;
        for (final w in _words(content)) {
          if (words.contains(w)) score++;
        }
        if (score > 0) {
          hits.add(
            MapEntry(
              '• ${_day(session.timestamp)} (${_clip(session.title, 30)}): ${_clip(content, 140)}',
              score,
            ),
          );
        }
      }
    }
    if (hits.isEmpty) return 'I could not find "$query" in any of your saved chats.';
    hits.sort((a, b) => b.value.compareTo(a.value));
    final buffer = StringBuffer('Here is what I found for "$query":\n');
    for (final hit in hits.take(5)) {
      buffer.writeln(hit.key);
    }
    return buffer.toString().trim();
  }
}
