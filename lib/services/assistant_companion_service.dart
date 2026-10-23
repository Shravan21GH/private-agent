class AssistantCompanionService {
  static String buildCompanionInstruction({required bool friendMode}) {
    if (friendMode) {
      return '''
You are Zax in friend mode.
Speak naturally, warmly, and directly like a helpful friend.
- Answer the question first in plain English.
- Keep replies clear and conversational.
- If the user asks about a concept, explain it simply first, then give the technical version if needed.
- For long input, summarize first and then give the useful next step.
- For email/message text, identify the main point, action items, and the most natural reply.
- If the user seems unsure, gently guide them without sounding robotic.
- Keep a friendly, human tone instead of stiff AI wording.
''';
    }

    return '''
You are Zax in Jarvis mode.
Keep replies sharp, efficient, polished, and proactive.
- Answer the key point first.
- Keep the message concise, confident, and useful.
- For long material, summarize fast and surface the main action items.
- When the user asks for drafts, write strong, polished text.
- Maintain a premium assistant tone.
''';
  }

  static String enrichPrompt(String rawText, {required bool friendMode}) {
    final text = rawText.trim();
    if (text.isEmpty) return '';

    final looksLikeEmail = text.contains('Subject:') ||
        text.contains('From:') ||
        text.contains('To:') ||
        text.contains('Hi ') ||
        text.contains('@') && text.contains('\n');

    final longInput = text.length > 260;
    final modeLabel = friendMode ? 'friend mode' : 'Jarvis mode';

    final buffer = StringBuffer();
    buffer.writeln('Companion context: $modeLabel');

    if (looksLikeEmail || longInput) {
      buffer.writeln(
        'This looks like a message, email, or long text. First give a fast summary in plain language, then list the important action items, then give a short suggested reply or next step.',
      );
    } else {
      buffer.writeln(
        'Answer clearly and directly. Use natural language and keep the response practical. Give the short answer first, then add a useful follow-up when it helps.',
      );
    }

    if (friendMode) {
      buffer.writeln(
        'Use a warm, conversational tone. Sound like a helpful friend, not a generic AI assistant.',
      );
    }

    buffer.writeln('User content:\n$text');
    return buffer.toString();
  }

  static List<String> suggestedActionChips(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) return const [];

    final suggestions = <String>[];
    suggestions.add('Explain this simply');
    suggestions.add('Summarize it for me');
    suggestions.add('Draft a quick reply');

    if (text.length > 180) {
      suggestions.add('Give me the main action items');
    }

    if (text.contains('@') || text.contains('Subject:') || text.contains('Hi ')) {
      suggestions.add('Summarize this email');
    }

    if (text.contains('plan') || text.contains('next step') || text.contains('goal')) {
      suggestions.add('Turn this into a plan');
    }

    return suggestions.take(5).toList();
  }

  static String quickEmailSummary(String emailText) {
    final text = emailText.trim();
    if (text.isEmpty) return 'No message content to summarize.';

    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final cleaned = lines.join(' ');
    final firstSentence = cleaned.length > 200
        ? cleaned.substring(0, 200).trim()
        : cleaned;

    return '''
Summary:
- Main idea: ${firstSentence}...
- Main ask: Identify the key action or request and respond quickly.
- Suggested reply: "Thanks for the update. I’ll review this and get back to you shortly."
''';
  }

  static String friendlyFollowUp(String prompt) {
    final text = prompt.trim();
    if (text.isEmpty) return 'I’m here — what do you want help with?';

    if (text.length < 50) {
      return 'Got it. I can explain it simply, give a sharper answer, or help you draft a reply.';
    }

    return 'I got it. I can break this down, summarize the important bits, or help you decide the best next step.';
  }
}
