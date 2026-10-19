import 'package:android_intent_plus/android_intent.dart';

/// Sets reminders through Android's own Clock app (the standard "set alarm"
/// request). Android only allows a time of day here, so a reminder can be at
/// most 24 hours ahead. Zax cannot see inside the Clock app, so it only ever
/// says the request was SENT, never that the alarm is certain to exist.
class ReminderService {
  /// Returns null when the request was sent, or a reason when it was not.
  Future<String?> scheduleAt(DateTime when, String label) async {
    final now = DateTime.now();
    if (!when.isAfter(now)) return 'that time has already passed.';
    if (when.difference(now) > const Duration(hours: 24)) {
      return 'Android alarms can only be set up to 24 hours ahead.';
    }
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.SET_ALARM',
        arguments: <String, dynamic>{
          'android.intent.extra.alarm.HOUR': when.hour,
          'android.intent.extra.alarm.MINUTES': when.minute,
          'android.intent.extra.alarm.MESSAGE': label,
          'android.intent.extra.alarm.SKIP_UI': true,
        },
      );
      await intent.launch();
      return null;
    } catch (e) {
      return 'the Clock app could not be reached ($e).';
    }
  }
}
