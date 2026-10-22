import '../models/agent_action.dart';
import '../models/chat_message.dart';
import 'app_launcher_service.dart';
import 'contacts_service.dart';
import 'communication_service.dart';
import 'alarm_service.dart';
import 'system_control_service.dart';
import 'shizuku_service.dart';
import 'screen_automation_service.dart';
import 'task_executor.dart';
import 'ai_service.dart';
import 'local_commands.dart';
import 'quick_commands.dart';

class ActionHandler {
  final AppLauncherService _appLauncher = AppLauncherService();
  final ContactsService _contacts = ContactsService();
  final CommunicationService _communication = CommunicationService();
  final AlarmService _alarm = AlarmService();
  final SystemControlService _systemControl = SystemControlService();
  final ShizukuService _shizuku = ShizukuService();
  final ScreenAutomationService _screenAutomation =
      ScreenAutomationService();

  ActionHandler() {
    // Load installed apps in the background.
    _appLauncher.warmUp();
  }

  final LocalCommands _local = LocalCommands();

  /// Shows a confirmation dialog before consequential actions.
  Future<bool> Function(String title, String message)? confirmAction;

  ShizukuService get shizuku => _shizuku;
  AppLauncherService get launcher => _appLauncher;
  ScreenAutomationService get screenAutomation => _screenAutomation;

  TaskExecutor? _currentExecutor;

  /// Execute an action and return the result.
  Future<AgentActionResult> execute(
    AgentAction action, {
    AiService? aiService,
    void Function(String)? onProgress,
  }) async {
    try {
      final problem = _validate(action);

      if (problem != null) {
        return AgentActionResult(
          actionType: action.action,
          success: false,
          details: problem,
        );
      }

      final question = _confirmationQuestion(action);

      if (question != null) {
        final ask = confirmAction;
        final approved =
            ask != null && await ask('Please confirm', question);

        if (!approved) {
          return AgentActionResult(
            actionType: action.action,
            success: false,
            details:
                'Cancelled: this action was not confirmed, so it was not done.',
          );
        }
      }

      String result;

      switch (action.action) {
        case 'open_app':
          result = await _appLauncher.openApp(
            action.params['app_name'] as String? ?? '',
          );
          break;

        case 'launch_package':
          result = await _appLauncher.openPackage(
            action.params['package_name'] as String? ?? '',
          );
          break;

        case 'make_call':
          result = await _communication.makeCall(
            contactName: action.params['contact_name'] as String?,
            phoneNumber: action.params['phone_number'] as String?,
          );
          break;

        case 'send_sms':
          result = await _communication.sendSms(
            contactName: action.params['contact_name'] as String?,
            phoneNumber: action.params['phone_number'] as String?,
            message: action.params['message'] as String? ?? '',
          );
          break;

        case 'search_contact':
          result = await _contacts.searchAndFormat(
            action.params['query'] as String? ?? '',
          );
          break;

        case 'set_alarm':
          result = await _alarm.setAlarm(
            hour: (action.params['hour'] as num?)?.toInt() ?? 0,
            minute: (action.params['minute'] as num?)?.toInt() ?? 0,
            label: action.params['label'] as String?,
          );
          break;

        case 'set_timer':
          result = await _alarm.setTimer(
            seconds:
                (action.params['seconds'] as num?)?.toInt() ?? 60,
            label: action.params['label'] as String?,
          );
          break;

        case 'set_volume':
          result = await _systemControl.setVolume(
            (action.params['level'] as num?)?.toInt() ?? 50,
          );
          break;

        case 'set_brightness':
          result = await _systemControl.setBrightness(
            (action.params['level'] as num?)?.toInt() ?? 50,
          );
          break;

        case 'run_adb_command':
          result = await _shizuku.runCommand(
            action.params['command'] as String? ?? '',
          );
          break;

        case 'send_email':
          result = await _communication.sendEmail(
            to: action.params['to'] as String? ?? '',
            subject: action.params['subject'] as String?,
            body: action.params['body'] as String?,
          );
          break;

        case 'open_url':
          result = await _appLauncher.openUrl(
            _normalizeUrl(
                  action.params['url'] as String? ?? '',
                ) ??
                '',
          );
          break;

        case 'read_screen':
          result = await _screenAutomation.getScreenDescription();
          break;

        case 'click_element':
          final text = action.params['text'] as String? ?? '';
          final success = await _screenAutomation.clickByText(text);
          result = success
              ? 'Clicked "$text"'
              : 'Could not find "$text" to click';
          break;

        case 'type_on_screen':
          final text = action.params['text'] as String? ?? '';
          final hint = action.params['field_hint'] as String?;
          final success = await _screenAutomation.typeText(
            text,
            fieldHint: hint,
          );
          result =
              success ? 'Typed "$text"' : 'Could not type into field';
          break;

        case 'scroll_screen':
          final direction =
              action.params['direction'] as String? ?? 'down';
          final success = await _screenAutomation.scroll(direction);
          result = success
              ? 'Scrolled $direction'
              : 'Could not scroll';
          break;

        case 'press_back':
          final success = await _screenAutomation.pressBack();
          result = success ? 'Pressed back' : 'Could not press back';
          break;

        case 'execute_task':
          final goal =
              action.params['goal'] as String? ?? action.response;

          if (aiService == null) {
            result = 'AI service not available for task execution.';
            break;
          }

          _currentExecutor = TaskExecutor(
            aiService: aiService,
            screenService: _screenAutomation,
            appLauncher: _appLauncher,
            shizukuService: _shizuku,
            onProgress: onProgress,
          );

          result = await _currentExecutor!.executeTask(goal);
          _currentExecutor = null;
          break;

        default:
          result = action.response;
      }

      return AgentActionResult(
        actionType: action.action,
        success: true,
        details: result,
      );
    } catch (e) {
      return AgentActionResult(
        actionType: action.action,
        success: false,
        details: 'Error: $e',
      );
    }
  }

  /// Validate an action before execution.
  String? _validate(AgentAction action) {
    final p = action.params;

    String text(String key) {
      final value = p[key];
      return value is String ? value.trim() : '';
    }

    num? number(String key) {
      final value = p[key];
      return value is num ? value : null;
    }

    switch (action.action) {
      case 'open_app':
        return text('app_name').isEmpty
            ? 'Which app should I open?'
            : null;

      case 'launch_package':
        return text('package_name').isEmpty
            ? 'No app package was given.'
            : null;

      case 'make_call':
        if (text('contact_name').isEmpty &&
            text('phone_number').isEmpty) {
          return 'Who should I call?';
        }
        return null;

      case 'send_sms':
        if (text('contact_name').isEmpty &&
            text('phone_number').isEmpty) {
          return 'Who should I text?';
        }
        if (text('message').isEmpty) {
          return 'What should the message say?';
        }
        return null;

      case 'send_email':
        return text('to').isEmpty
            ? 'Who should the email go to?'
            : null;

      case 'open_url':
        return _normalizeUrl(text('url')) == null
            ? 'That is not a valid web address.'
            : null;

      case 'set_volume':
      case 'set_brightness':
        final level = number('level');
        if (level == null || level < 0 || level > 100) {
          return 'The level must be a number from 0 to 100.';
        }
        return null;

      case 'set_alarm':
        final hour = number('hour');
        final minute = number('minute');

        if (hour == null ||
            minute == null ||
            hour < 0 ||
            hour > 23 ||
            minute < 0 ||
            minute > 59) {
          return 'An alarm needs an hour (0-23) and a minute (0-59).';
        }
        return null;

      case 'set_timer':
        final seconds = number('seconds');
        if (seconds == null || seconds < 1 || seconds > 86400) {
          return 'A timer must be between 1 second and 24 hours.';
        }
        return null;

      case 'run_adb_command':
        return text('command').isEmpty
            ? 'No command was given.'
            : null;

      default:
        return null;
    }
  }

  /// Ask for confirmation before consequential actions.
  String? _confirmationQuestion(AgentAction action) {
    final p = action.params;

    String text(String key) {
      final value = p[key];
      return value is String ? value.trim() : '';
    }

    final who = text('contact_name').isNotEmpty
        ? text('contact_name')
        : text('phone_number');

    switch (action.action) {
      case 'make_call':
        return 'Call $who?';

      case 'send_sms':
        return 'Send this text message to $who?\n\n${text('message')}';

      case 'send_email':
        final subject = text('subject');
        return 'Send an email to ${text('to')}'
            '${subject.isEmpty ? '' : ' with the subject "$subject"'}?';

      case 'run_adb_command':
        return 'Run this device command?\n\n${text('command')}';

      default:
        return null;
    }
  }

  /// Normalize a web address. Only HTTP and HTTPS are allowed.
  String? _normalizeUrl(String raw) {
    var url = raw.trim();

    if (url.isEmpty || url.contains(' ')) return null;
    if (!url.contains('://')) url = 'https://$url';

    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return null;
    }

    if (uri.host.isEmpty || !uri.host.contains('.')) {
      return null;
    }

    return uri.toString();
  }

  /// Handle simple commands without involving the AI first.
  Future<String?> runQuickCommand(String text) async {
    final local = await _local.handle(text);
    if (local != null) return local;

    final command = QuickCommand.parse(text);

    try {
      String result;

      switch (command.type) {
        case QuickCommandType.openApp:
          result = await _appLauncher.openApp(command.target);
          break;

        case QuickCommandType.playStoreSearch:
          result = await _appLauncher.openPlayStoreSearch(
            command.target,
          );
          break;

        case QuickCommandType.unknown:
          return null;
      }

      return result.startsWith('Opened') ? result : null;
    } catch (_) {
      return null;
    }
  }

  /// Cancel the currently running task.
  void cancelTask() {
    _currentExecutor?.cancel();
  }
}
