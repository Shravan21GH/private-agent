import 'package:flutter/material.dart';

/// The 4 Zax modes. Each one has its own colour, hint text, suggestions and
/// (for Study and Programming) its own extra instructions for the AI.
enum ZaxMode { normal, study, image, programming }

extension ZaxModeInfo on ZaxMode {
  String get label {
    switch (this) {
      case ZaxMode.normal:
        return 'Normal';
      case ZaxMode.study:
        return 'Study';
      case ZaxMode.image:
        return 'Image';
      case ZaxMode.programming:
        return 'Code';
    }
  }

  IconData get icon {
    switch (this) {
      case ZaxMode.normal:
        return Icons.bolt_rounded;
      case ZaxMode.study:
        return Icons.school_rounded;
      case ZaxMode.image:
        return Icons.palette_rounded;
      case ZaxMode.programming:
        return Icons.code_rounded;
    }
  }

  /// Normal = gold, Study = green, Image = blue, Programming = red.
  Color get color {
    switch (this) {
      case ZaxMode.normal:
        return const Color(0xFFFFB020);
      case ZaxMode.study:
        return const Color(0xFF22E07A);
      case ZaxMode.image:
        return const Color(0xFF2D9CFF);
      case ZaxMode.programming:
        return const Color(0xFFFF3B3B);
    }
  }

  String get tagline {
    switch (this) {
      case ZaxMode.normal:
        return 'How can I help you?';
      case ZaxMode.study:
        return 'What shall we learn today?';
      case ZaxMode.image:
        return 'What should I imagine?';
      case ZaxMode.programming:
        return 'What are we building?';
    }
  }

  String get hint {
    switch (this) {
      case ZaxMode.normal:
        return 'Type a command...';
      case ZaxMode.study:
        return 'Ask me to teach you something...';
      case ZaxMode.image:
        return 'Describe the image you want...';
      case ZaxMode.programming:
        return 'Ask a coding question or paste an error...';
    }
  }

  /// Extra instructions added to the AI's chat prompt.
  /// Normal and Image add nothing (Image is handled by the home screen).
  String get instruction {
    switch (this) {
      case ZaxMode.study:
        return 'STUDY MODE: You are a patient, friendly tutor. Explain step by '
            'step in simple words, use small examples, and finish with one '
            'short question to check understanding. Offer summaries, '
            'flashcards or a revision plan when they would help.';
      case ZaxMode.programming:
        return 'PROGRAMMING MODE: You are an expert Roblox Studio developer '
            'who writes Luau. Build exactly the game and features the user '
            'asks for and do not invent extra features. Use real Roblox '
            'services and APIs only (for example Players, ReplicatedStorage, '
            'ServerScriptService, RemoteEvent, DataStoreService, '
            'TweenService) and never make up methods. If essential details '
            'are missing (what the game is, server or client side, what '
            'triggers the feature), ask one or two short questions before '
            'writing code. Always say where each script goes in Roblox '
            'Studio: the script type (Script, LocalScript or ModuleScript) '
            'and the container it belongs in. For bugs, fix only the broken '
            'part instead of rewriting everything. Put code in fenced lua '
            'code blocks. You cannot run Roblox Studio, so say clearly that '
            'your code is untested and what the user should check when they '
            'test it. For non-Roblox programming questions, answer normally '
            'with correct, complete code and plain explanations. Assume the '
            'user may be a beginner.';
      case ZaxMode.normal:
        return 'NORMAL MODE: Talk like a friendly, relaxed person: warm, '
            'natural and clear. Keep answers short unless the user asks for '
            'detail, and follow their instructions exactly. If you do not '
            'know something, say so instead of guessing. You cannot open '
            'apps or change phone settings in your own reply; the Zax app '
            'does that when the user says a clear command such as "open '
            'YouTube" or "set a timer for 10 minutes". For longer phone '
            'tasks, tell them to switch to the phone-control (Agent) mode.';
      case ZaxMode.image:
        return '';
    }
  }

  List<String> get suggestions {
    switch (this) {
      case ZaxMode.normal:
        return [
          'Write a professional email',
          'Explain quantum computing simply',
          'Brainstorm mobile app ideas',
          'Write a poem about robots',
        ];
      case ZaxMode.study:
        return [
          'Explain photosynthesis step by step',
          'Quiz me on World War 2',
          'Make flashcards for algebra',
          'Create a 7 day study plan',
        ];
      case ZaxMode.image:
        return [
          'A golden dragon above a neon city',
          'A cozy cabin in snowy mountains',
          'A futuristic robot portrait',
          'A calm beach at sunset, painting style',
        ];
      case ZaxMode.programming:
        return [
          'Make a part that kills players on touch',
          'Create a coin collecting system',
          'Why do I get "attempt to index nil"?',
          'Add a simple shop GUI',
        ];
    }
  }
}
