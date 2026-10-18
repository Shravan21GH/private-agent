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
        return 'PROGRAMMING MODE: You are an expert programmer. Give correct, '
            'complete code in fenced code blocks with the language named. '
            'Explain briefly how it works. When the user shares an error, '
            'explain the cause in simple words and give the exact fix. '
            'Assume the user may be a beginner unless they show otherwise.';
      case ZaxMode.normal:
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
          'Explain what a variable is',
          'Write a Python calculator',
          'Why does my app crash on start?',
          'Explain Flutter widgets simply',
        ];
    }
  }
}
