/// Quick commands that Zax can carry out at once, without asking the AI:
/// time and date, timers, alarms, volume, brightness, calls, web and map
/// searches, and opening websites. Anything not clearly one of these returns
/// null and goes on to the AI.
enum InstantType {
  time,
  timer,
  alarm,
  volume,
  brightness,
  call,
  googleSearch,
  youtubeSearch,
  mapsSearch,
  website,
}

class InstantCommand {
  final InstantType type;

  /// Text to search for, a name to call, or a web address.
  final String text;

  /// Timer length in seconds, volume or brightness level, or alarm hour.
  final int number;

  /// Alarm minute.
  final int minute;

  const InstantCommand(this.type, {this.text = '', this.number = 0, this.minute = 0});

  static final RegExp _prefix = RegExp(
    r'^(?:please\s+)?(?:(?:hey|ok)\s+)?(?:zax[,\s]+)?(?:please\s+)?',
    caseSensitive: false,
  );

  static final RegExp _time = RegExp(
    r"^(?:what(?:'s|\s+is)?\s+(?:the\s+)?(?:current\s+)?(?:time|date|day)"
    r'(?:\s+(?:is\s+it|now|today|right\s+now))?|what\s+(?:time|day)\s+is\s+it'
    r'(?:\s+(?:now|today|right\s+now))?|tell\s+me\s+the\s+(?:time|date))$',
    caseSensitive: false,
  );

  static final RegExp _timer = RegExp(
    r'^(?:set|start)\s+(?:a\s+)?timer\s+(?:for\s+)?(\d{1,4})\s*'
    r'(seconds?|secs?|minutes?|mins?|hours?|hrs?)$',
    caseSensitive: false,
  );

  static final RegExp _alarm = RegExp(
    r'^set\s+(?:an?\s+)?alarm\s+(?:for|at)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$',
    caseSensitive: false,
  );

  static final RegExp _volume = RegExp(
    r'^(?:set\s+)?volume\s+(?:to\s+)?(\d{1,3})\s*%?$',
    caseSensitive: false,
  );

  static final RegExp _brightness = RegExp(
    r'^(?:set\s+)?brightness\s+(?:to\s+)?(\d{1,3})\s*%?$',
    caseSensitive: false,
  );

  static final RegExp _call = RegExp(
    r'^(?:call|phone|dial)\s+(.+)$',
    caseSensitive: false,
  );

  static final RegExp _searchOn = RegExp(
    r'^(?:search|google|look\s*up|find|play)\s+(?:for\s+)?(.+?)\s+on\s+'
    r'(google\s+maps|maps|youtube|google)$',
    caseSensitive: false,
  );

  static final RegExp _googleSearch = RegExp(
    r'^(?:search|google|look\s*up)\s+(?:for\s+)?(.+)$',
    caseSensitive: false,
  );

  static final RegExp _navigate = RegExp(
    r'^(?:navigate|directions?|take\s+me)\s+(?:to\s+)?(.+)$',
    caseSensitive: false,
  );

  static final RegExp _website = RegExp(
    r'^(?:open|go\s+to|visit|browse)\s+(?:the\s+)?(?:website\s+)?'
    r'((?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?:/\S*)?)$',
    caseSensitive: false,
  );

  static const Set<String> _notAName = {
    'me', 'it', 'this', 'that', 'him', 'her', 'them', 'us', 'you', 'back',
    'off', 'out', 'in', 'on', 'up', 'a', 'an', 'the',
  };

  static InstantCommand? parse(String input) {
    var text = input.trim().replaceAll(RegExp(r'[.!?]+$'), '');
    text = text.replaceFirst(_prefix, '').trim();
    if (text.isEmpty) return null;
    final lower = text.toLowerCase();

    // Play Store searches are handled elsewhere.
    if (lower.contains('play store') || lower.contains('playstore')) return null;

    if (_time.hasMatch(lower)) return const InstantCommand(InstantType.time);

    final timer = _timer.firstMatch(lower);
    if (timer != null) {
      final n = int.parse(timer.group(1)!);
      final unit = timer.group(2)!;
      final seconds = unit.startsWith('h') ? n * 3600 : (unit.startsWith('m') ? n * 60 : n);
      if (seconds >= 1 && seconds <= 86400) {
        return InstantCommand(InstantType.timer, number: seconds);
      }
      return null;
    }

    final alarm = _alarm.firstMatch(lower);
    if (alarm != null) {
      var hour = int.parse(alarm.group(1)!);
      final minute = int.tryParse(alarm.group(2) ?? '') ?? 0;
      final ap = alarm.group(3);
      if (ap == 'pm' && hour < 12) hour += 12;
      if (ap == 'am' && hour == 12) hour = 0;
      if (hour > 23 || minute > 59) return null;
      return InstantCommand(InstantType.alarm, number: hour, minute: minute);
    }

    final volume = _volume.firstMatch(lower);
    if (volume != null) {
      final level = int.parse(volume.group(1)!);
      return level <= 100 ? InstantCommand(InstantType.volume, number: level) : null;
    }
    final brightness = _brightness.firstMatch(lower);
    if (brightness != null) {
      final level = int.parse(brightness.group(1)!);
      return level <= 100 ? InstantCommand(InstantType.brightness, number: level) : null;
    }

    final website = _website.firstMatch(text);
    if (website != null) return InstantCommand(InstantType.website, text: website.group(1)!);

    final on = _searchOn.firstMatch(text);
    if (on != null) {
      final query = on.group(1)!.trim();
      final where = on.group(2)!.toLowerCase();
      if (where.contains('maps')) return InstantCommand(InstantType.mapsSearch, text: query);
      if (where == 'youtube') return InstantCommand(InstantType.youtubeSearch, text: query);
      return InstantCommand(InstantType.googleSearch, text: query);
    }

    final nav = _navigate.firstMatch(text);
    if (nav != null) return InstantCommand(InstantType.mapsSearch, text: nav.group(1)!.trim());

    final call = _call.firstMatch(text);
    if (call != null) {
      final name = call.group(1)!.trim();
      final words = name.split(RegExp(r'\s+'));
      if (words.length <= 3 && !_notAName.contains(words.first.toLowerCase())) {
        return InstantCommand(InstantType.call, text: name);
      }
      return null;
    }

    final search = _googleSearch.firstMatch(text);
    if (search != null) {
      final query = search.group(1)!.trim();
      // "search contact Mom" is a contacts action for the AI, not a web search.
      if (query.toLowerCase().startsWith('contact')) return null;
      return InstantCommand(InstantType.googleSearch, text: query);
    }
    return null;
  }
}
