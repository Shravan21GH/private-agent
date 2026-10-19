import 'package:flutter/foundation.dart';

/// Defines the types of quick commands your application handles
enum QuickCommandType {
  openApp,
  playStoreSearch,
  unknown,
}

/// Handles parsing and structuring of quick command strings
class QuickCommand {
  final QuickCommandType type;
  final String target;

  QuickCommand({
    required this.type,
    required this.target,
  });

  /// Parses raw input text into a structured QuickCommand object
  factory QuickCommand.parse(String text) {
    final cleanedText = text.trim().toLowerCase();

    if (cleanedText.startsWith('open ')) {
      final appTarget = text.substring(5).trim();
      return QuickCommand(
        type: QuickCommandType.openApp,
        target: appTarget,
      );
    } else if (cleanedText.startsWith('search play store for ')) {
      final searchTarget = text.substring(22).trim();
      return QuickCommand(
        type: QuickCommandType.playStoreSearch,
        target: searchTarget,
      );
    }

    return QuickCommand(
      type: QuickCommandType.unknown,
      target: text,
    );
  }
}
