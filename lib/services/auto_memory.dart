import 'memory_store.dart';

/// Quietly saves things the user clearly says about themselves, such as
/// "my name is Sam" or "I love basketball", so Zax remembers them without
/// being told to. Questions are ignored. Anything that looks like a password,
/// key or other personal/sensitive detail is NEVER saved automatically (the
/// memory store refuses it); the user can still ask Zax to remember it on
/// purpose.
class AutoMemory {
  AutoMemory._();

  static final RegExp _name = RegExp(
    r"^(?:my\s+name\s+is|i\s+am\s+called|call\s+me)\s+[A-Za-z][A-Za-z .'-]{0,30}$",
    caseSensitive: false,
  );

  static final RegExp _likes = RegExp(
    r"^i\s+(?:really\s+|absolutely\s+)?(?:like|love|enjoy|prefer|hate|dislike|can'?t\s+stand)\s+"
    r'(?!(?:it|that|this|you|them|how|when|what|the\s+way)\b).{2,120}$',
    caseSensitive: false,
  );

  static final RegExp _favourite = RegExp(
    r'^my\s+favou?rite\s+[a-z ]{2,25}\s+(?:is|are)\s+.{1,80}$',
    caseSensitive: false,
  );

  static final RegExp _about = RegExp(
    r"^(?:i\s+(?:live\s+in|work\s+(?:at|as|in|for)|go\s+to|study\s+(?:at|in))"
    r"|i(?:'m|\s+am)\s+(?:studying|learning|building|working\s+on))\s+.{2,100}$",
    caseSensitive: false,
  );

  /// Returns the text that was saved, or null when nothing was saved.
  static Future<String?> maybeSave(String input) async {
    final text = input.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.length < 8 || text.length > 160) return null;
    if (text.endsWith('?')) return null;
    final clean = text.replaceAll(RegExp(r'[.!]+$'), '');

    String? kind;
    if (_name.hasMatch(clean) || _about.hasMatch(clean)) {
      kind = 'fact';
    } else if (_favourite.hasMatch(clean)) {
      kind = 'fact';
    } else if (_likes.hasMatch(clean)) {
      kind = 'preference';
    }
    if (kind == null) return null;

    try {
      final result = await MemoryStore.instance.remember(
        'User said: $clean',
        kind: kind,
      );
      return result.status == MemoryStatus.saved ? clean : null;
    } catch (_) {
      return null;
    }
  }
}
