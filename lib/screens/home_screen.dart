import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/chat_message.dart';
import '../services/ai_service.dart';
import '../services/action_handler.dart';
import '../services/voice_service.dart';
import '../widgets/message_bubble.dart';
import '../services/telegram_service.dart';
import '../services/chat_history_service.dart';
import '../services/notification_service.dart';
import '../services/auto_memory.dart';
import '../services/chat_recall.dart';
import '../services/zax_fast_router.dart';
import 'memory_screen.dart';
import 'mode_providers_screen.dart';
import 'notes_screen.dart';
import 'tasks_screen.dart';
import 'settings_screen.dart';
import 'task_history_screen.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import '../main.dart';
import '../config/feature_flags.dart';
import '../config/zax_mode.dart';
import '../widgets/zax_core.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AiService _aiService = AiService();
  final ActionHandler _actionHandler = ActionHandler();
  final VoiceService _voiceService = VoiceService();
  final NotificationService _notificationService = NotificationService();
  late final TelegramService _telegramService;
  late final ZaxFastRouter _fastRouter;

  final List<ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _isListening = false;

  // Custom switch state: 'chat' or 'agent'
  String _mode = 'chat';

  // Zax mode: normal (gold), study (green), image (blue), programming (red)
  ZaxMode _zaxMode = ZaxMode.normal;

  // Chat Session state tracking
  String _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
  String _sessionTitle = '';

  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  Timer? _overlayHistoryTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _telegramService = TelegramService(_actionHandler, _aiService);
    _fastRouter = ZaxFastRouter(
      actionHandler: _actionHandler,
      aiService: _aiService,
    );
    // Calls, texts and emails always ask first. (Before this was connected,
    // those actions were always cancelled because nothing could say "yes".)
    _actionHandler.confirmAction = (title, message) async {
      if (!mounted) return false;
      final approved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Yes, do it'),
            ),
          ],
        ),
      );
      return approved ?? false;
    };
    _initServices();
    _startOverlayHistorySync();
    // Register as the handler for overlay bubble tasks
    onOverlayTask = (task) => _sendMessage(task);
  }

  Future<void> _initServices() async {
    await _aiService.init();
    await _notificationService.requestPermission();
    await _voiceService.init();
    await _telegramService.init();
    await _actionHandler.shizuku.checkAvailability();

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _saveSession() async {
    if (_messages.isEmpty) return;

    // Set first user message as session title if not set
    if (_sessionTitle.isEmpty) {
      final firstUserMsg = _messages.firstWhere(
        (m) => m.isUser,
        orElse: () => ChatMessage(role: 'user', content: 'New Chat'),
      );
      _sessionTitle = firstUserMsg.content.length > 28
          ? '${firstUserMsg.content.substring(0, 25)}...'
          : firstUserMsg.content;
    }

    final session = ChatSession(
      id: _sessionId,
      title: _sessionTitle,
      timestamp: DateTime.now(),
      messages: _messages.map((m) => m.toJson()).toList(),
    );

    await ChatHistoryService.saveSession(session);
  }

  void _showStatus(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  Future<void> _autoRemember(String text) async {
    final saved = await AutoMemory.maybeSave(text);
    if (saved != null) _showStatus('🧠 Remembered: $saved');
  }

  /// Clear commands (open an app, timers, notes, tasks, camera, ...) are done
  /// on the phone straight away without waiting for the AI. Returns true when
  /// the message was handled here.
  Future<bool> _tryFastCommand(String text) async {
    FastReply? reply;
    setState(() => _isLoading = true);
    try {
      reply = await _fastRouter.tryHandle(text, onStatus: _showStatus);
    } catch (e) {
      reply = FastReply(
        'Something went wrong: ${e.toString().replaceFirst('Exception: ', '')}',
      );
    }
    if (reply == null) {
      if (mounted) setState(() => _isLoading = false);
      return false;
    }
    if (!mounted) return true;
    final image = reply.imagePath;
    final shown = image == null
        ? reply.text
        : '![photo](${Uri.file(image)})\n\n${reply.text}';
    setState(() {
      _messages.add(ChatMessage(role: 'user', content: text));
      _messages.add(ChatMessage(role: 'assistant', content: shown));
      _isLoading = false;
    });
    _textController.clear();
    _scrollToBottom();
    _aiService.addHistoryMessage('user', text);
    _aiService.addHistoryMessage('assistant', reply.text);
    await _saveSession();
    ChatRecall.refresh();
    if (_zaxMode != ZaxMode.programming && reply.text.length <= 300) {
      _voiceService.speak(reply.text);
    }
    return true;
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    // Tell the AI which Zax mode is active (only affects normal chat replies)
    _aiService.modeInstruction = _zaxMode.instruction;
    // Choose that mode's own providers, and tell chat recall which chat is open
    _aiService.activeMode = _zaxMode.name;
    ChatRecall.currentSessionId = _sessionId;

    // Image mode: make a picture instead of asking the AI for text
    if (_zaxMode == ZaxMode.image && _mode == 'chat') {
      await _generateImage(text.trim());
      return;
    }

    // Instant commands first: no waiting for the AI.
    if (await _tryFastCommand(text.trim())) return;
    if (_mode == 'chat') unawaited(_autoRemember(text.trim()));

    final userMessage = ChatMessage(role: 'user', content: text.trim());
    setState(() {
      _messages.add(userMessage);
      _isLoading = true;
    });
    _updateOverlayState();
    _textController.clear();
    _scrollToBottom();
    await _saveSession();

    // Add empty placeholder assistant message for streaming
    final assistantMessage = ChatMessage(role: 'assistant', content: '');
    setState(() {
      _messages.add(assistantMessage);
    });
    final assistantIndex = _messages.length - 1;

    try {
      final isAgent = _mode == 'agent';
      final stream = _aiService
          .sendMessageStream(text.trim(), isAgentMode: isAgent)
          .timeout(
            const Duration(seconds: 90),
            onTimeout: (sink) {
              sink.addError(
                TimeoutException(
                  'The model did not return visible text within 90 seconds.',
                ),
              );
              sink.close();
            },
          );
      String accumulated = '';
      DateTime lastPaint = DateTime.fromMillisecondsSinceEpoch(0);

      // Redraw the growing answer at most ~12 times a second instead of for
      // every single word. This is what keeps the screen smooth.
      void paintAnswer() {
        if (!mounted) return;
        setState(() {
          _messages[assistantIndex] = ChatMessage(
            role: 'assistant',
            content: accumulated,
            timestamp: assistantMessage.timestamp,
          );
        });
        _scrollToBottom();
        lastPaint = DateTime.now();
      }

      await for (final chunk in stream) {
        accumulated += chunk;
        if (DateTime.now().difference(lastPaint).inMilliseconds >= 80) {
          paintAnswer();
        }
      }
      paintAnswer();
      await _saveSession();
      ChatRecall.refresh();
      if (_aiService.fallbackNote.isNotEmpty) {
        _showStatus(_aiService.fallbackNote);
      }

      // Check if it's an action
      final action = _aiService.parseAction(accumulated);

      if (action != null) {
        // If it's an action, we remove the raw JSON message from display
        setState(() {
          _messages.removeAt(assistantIndex);
        });

        await _showTaskProgressOverlay('Starting: ${text.trim()}');

        // Execute the action (pass aiService for multi-step tasks)
        final result = await _actionHandler.execute(
          action,
          aiService: _aiService,
          onProgress: (msg) {
            developer.log('Task progress: $msg', name: 'PrivateAgent');
            _sendOverlayEvent('OVERLAY_PROGRESS', msg);
            if (mounted) {
              setState(() {
                _messages.add(
                  ChatMessage(role: 'assistant', content: '⏳ $msg'),
                );
              });
              _scrollToBottom();
            }
          },
        );

        setState(() {
          _messages.add(
            ChatMessage(
              role: 'assistant',
              content: result.success
                  ? (action.response.isNotEmpty
                        ? action.response
                        : (result.details ?? 'Done.'))
                  : (action.response.isNotEmpty
                        ? '${action.response}\n\n⚠️ ${result.details}'
                        : '⚠️ ${result.details}'),
              actionResult: result,
            ),
          );
        });
        _sendOverlayEvent(
          'OVERLAY_TASK_FINISHED',
          result.success
              ? (result.details ?? 'Task complete.')
              : 'Task failed: ${result.details ?? 'Unknown error'}',
        );
        if (action.action != 'execute_task') {
          await _notificationService.showTaskCompleteNotification(
            result.success ? 'Task Completed' : 'Task Failed',
            result.details ??
                (result.success
                    ? 'Agent finished its goal.'
                    : 'Agent could not complete the task.'),
          );
        }
        await _saveSession();
      } else {
        // Plain text response, we already rendered it, just speak it
        if (_zaxMode != ZaxMode.programming) {
          _voiceService.speak(accumulated);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (_messages.isNotEmpty && _messages.length > assistantIndex) {
            _messages.removeAt(assistantIndex);
          }
          _messages.add(
            ChatMessage(
              role: 'assistant',
              content: 'Error: ${e.toString().replaceFirst('Exception: ', '')}',
            ),
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        _scrollToBottom();
        _updateOverlayState();
      }
    }
  }

  Future<void> _generateImage(String prompt) async {
    final seed = DateTime.now().millisecondsSinceEpoch % 100000;
    final encoded = Uri.encodeComponent(
      prompt,
    ).replaceAll('(', '%28').replaceAll(')', '%29');
    final url =
        'https://image.pollinations.ai/prompt/$encoded?width=768&height=768&nologo=true&seed=$seed';
    setState(() {
      _messages.add(ChatMessage(role: 'user', content: prompt));
      _messages.add(
        ChatMessage(
          role: 'assistant',
          content: '🎨 Creating your image... (it can take a few seconds)\n\n![image]($url)',
        ),
      );
    });
    _textController.clear();
    _scrollToBottom();
    await _saveSession();
  }

  Future<void> _showTaskProgressOverlay(String message) async {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    if (!await FlutterOverlayWindow.isPermissionGranted()) return;

    // Never cover PrivateAgent itself. The lifecycle observer will create the
    // overlay after an automated action moves this app to the background.
    if (_appLifecycleState != AppLifecycleState.paused) return;

    if (!await FlutterOverlayWindow.isActive()) {
      await FlutterOverlayWindow.showOverlay(
        enableDrag: true,
        overlayTitle: 'PrivateAgent',
        overlayContent: 'Performing task...',
        flag: OverlayFlag.focusPointer,
        alignment: OverlayAlignment.centerRight,
        visibility: NotificationVisibility.visibilitySecret,
        positionGravity: PositionGravity.auto,
        startPosition: const OverlayPosition(0, 200),
        width: 56,
        height: 56,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    // Keep the overlay minimized during automation. The user can still tap the
    // bubble to open the full conversation whenever they choose.
    _sendOverlayEvent('OVERLAY_TASK_STARTED', message);
  }

  void _sendOverlayEvent(String type, String message) {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    final safeMessage = message.replaceAll('|', ' ');
    unawaited(
      FlutterOverlayWindow.shareData(
        '$type|$safeMessage',
      ).timeout(const Duration(seconds: 2)).catchError((Object _) {}),
    );
  }

  Future<void> _sendOverlayHistorySnapshot() async {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    final history = base64Encode(
      utf8.encode(
        jsonEncode(_messages.map((message) => message.toJson()).toList()),
      ),
    );
    try {
      await FlutterOverlayWindow.shareData(
        'OVERLAY_HISTORY|$history',
      ).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  bool _scrollPending = false;

  void _scrollToBottom() {
    if (_scrollPending) return;
    _scrollPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollPending = false;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _toggleVoice() async {
    if (_isListening) {
      await _voiceService.stopListening();
      setState(() => _isListening = false);
      return;
    }

    setState(() => _isListening = true);

    await _voiceService.startListening(
      onResult: (text) {
        _sendMessage(text);
      },
      onDone: () {
        if (mounted) {
          setState(() => _isListening = false);
        }
      },
    );
  }

  void _startNewChat() {
    setState(() {
      _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
      _sessionTitle = '';
      _messages.clear();
      _aiService.clearHistory();
    });
  }

  void _loadChatSession(ChatSession session) {
    setState(() {
      _sessionId = session.id;
      _sessionTitle = session.title;
      _messages.clear();
      for (final m in session.messages) {
        _messages.add(ChatMessage.fromJson(m));
      }

      _aiService.clearHistory();
      for (final m in _messages) {
        if (m.actionResult != null) continue;
        _aiService.addHistoryMessage(m.role, m.content);
      }
    });
    _scrollToBottom();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _overlayHistoryTimer?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _voiceService.dispose();
    _telegramService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      _appLifecycleState = state;
    });
    if (state == AppLifecycleState.resumed) {
      _startOverlayHistorySync();
      unawaited(_handleAppForegrounded());
    } else {
      _overlayHistoryTimer?.cancel();
      _updateOverlayState();
    }
  }

  void _startOverlayHistorySync() {
    _overlayHistoryTimer?.cancel();
    if (!FeatureFlags.floatingOverlayEnabled) return;
    unawaited(_importOverlayChatHistory());
    _overlayHistoryTimer = Timer.periodic(const Duration(milliseconds: 500), (
      _,
    ) {
      if (_appLifecycleState == AppLifecycleState.resumed) {
        unawaited(_importOverlayChatHistory());
      }
    });
  }

  Future<void> _handleAppForegrounded() async {
    await _updateOverlayState();
    await _importOverlayChatHistory();
  }

  Future<void> _importOverlayChatHistory() async {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    if (_importingOverlayHistory) return;
    _importingOverlayHistory = true;
    try {
      final handoff = await ChatHistoryService.consumeOverlayMessages();
      if (!mounted || handoff.isEmpty) return;

      final imported = handoff.map(ChatMessage.fromJson).toList();
      for (final message in imported) {
        if (message.actionResult == null) {
          _aiService.addHistoryMessage(message.role, message.content);
        }
      }
      setState(() {
        _messages.addAll(imported);
      });
      _scrollToBottom();
      await _saveSession();
    } finally {
      _importingOverlayHistory = false;
    }
  }

  int _overlayUpdateGeneration = 0;
  bool _importingOverlayHistory = false;

  Future<void> _updateOverlayState() async {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    final generation = ++_overlayUpdateGeneration;
    final isBackground = _appLifecycleState == AppLifecycleState.paused;
    final shouldBeActive = isBackground;

    bool granted = await FlutterOverlayWindow.isPermissionGranted();
    if (!granted || generation != _overlayUpdateGeneration) return;

    bool active = await FlutterOverlayWindow.isActive();
    if (generation != _overlayUpdateGeneration) return;
    if (shouldBeActive && !active) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (generation != _overlayUpdateGeneration) return;
      if (_appLifecycleState != AppLifecycleState.paused) return;
      if (await FlutterOverlayWindow.isActive()) return;
      await FlutterOverlayWindow.showOverlay(
        enableDrag: true,
        overlayTitle: "PrivateAgent",
        overlayContent: _isLoading
            ? "Performing task..."
            : "Floating Assistant",
        flag: OverlayFlag.focusPointer,
        alignment: OverlayAlignment.centerRight,
        visibility: NotificationVisibility.visibilitySecret,
        positionGravity: PositionGravity.auto,
        startPosition: const OverlayPosition(0, 200),
        width: 56,
        height: 56,
      );
      if (_isLoading && _appLifecycleState == AppLifecycleState.paused) {
        // Give the overlay isolate time to attach its listener, then send the
        // full active conversation. A second snapshot makes cold starts
        // reliable without duplicating messages because the overlay replaces
        // its list atomically.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await _sendOverlayHistorySnapshot();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (_isLoading && _appLifecycleState == AppLifecycleState.paused) {
          await _sendOverlayHistorySnapshot();
        }
      }
    } else if (shouldBeActive && active && _isLoading) {
      await _sendOverlayHistorySnapshot();
    } else if (!shouldBeActive && active) {
      try {
        await FlutterOverlayWindow.shareData(
          'OVERLAY_RESET|',
        ).timeout(const Duration(milliseconds: 150));
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (generation != _overlayUpdateGeneration) return;
      if (_appLifecycleState == AppLifecycleState.paused) return;
      await FlutterOverlayWindow.closeOverlay();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Zax always uses the dark HUD look
    const isDark = true;

    return Theme(
      data: _hudTheme(context),
      child: Scaffold(
      backgroundColor: const Color(0xFF04070B),
      appBar: AppBar(
        title: RichText(
          text: TextSpan(
            style: const TextStyle(fontSize: 20, color: Colors.white),
            children: [
              TextSpan(
                text: 'ZAX',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: _zaxMode.color,
                  letterSpacing: 4,
                ),
              ),
              TextSpan(
                text: '  ${_zaxMode.label.toUpperCase()}',
                style: const TextStyle(
                  fontWeight: FontWeight.w400,
                  fontSize: 11,
                  letterSpacing: 2,
                  color: Colors.white54,
                ),
              ),
            ],
          ),
        ),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu_rounded),
            tooltip: 'Menu',
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: 'New chat',
            onPressed: _isLoading ? null : _startNewChat,
          ),
          // Settings Action
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(
                    aiService: _aiService,
                    shizukuService: _actionHandler.shizuku,
                    screenAutomationService: _actionHandler.screenAutomation,
                    telegramService: _telegramService,
                  ),
                ),
              );
              await _actionHandler.shizuku.checkAvailability();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      drawer: _buildDrawer(context, isDark),
      body: Stack(
        children: [
          // Background mesh glows
          _buildBackgroundGlows(isDark),

          Column(
            children: [
              // Glowing Zax core + the 4 modes
              _buildCore(),
              _buildZaxModeChips(),

              // Chat / Agent (phone control) switch
              _buildModeSelector(isDark),

              // API key warning banner
              if (!_aiService.isConfigured)
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orangeAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.orangeAccent.withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.orange,
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'API not configured. Tap Settings to add details.',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => SettingsScreen(
                                aiService: _aiService,
                                shizukuService: _actionHandler.shizuku,
                                screenAutomationService:
                                    _actionHandler.screenAutomation,
                                telegramService: _telegramService,
                              ),
                            ),
                          );
                          if (mounted) setState(() {});
                        },
                        child: const Text('Configure'),
                      ),
                    ],
                  ),
                ),

              // Chat content area
              Expanded(
                child: _messages.isEmpty
                    ? _buildEmptyState(isDark)
                    : ListView.builder(
                        controller: _scrollController,
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final streaming =
                              _isLoading && index == _messages.length - 1;
                          return RepaintBoundary(
                            child: MessageBubble(
                              message: _messages[index],
                              streaming: streaming,
                            ),
                          );
                        },
                      ),
              ),

              // Think loading indicator
              if (_isLoading)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white70,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Thinking...',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? const Color(0xFF9E9BAC)
                              : const Color(0xFF6C6A7C),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () {
                          _actionHandler.cancelTask();
                          setState(() {
                            _isLoading = false;
                          });
                        },
                        icon: const Icon(
                          Icons.stop_circle_rounded,
                          size: 16,
                          color: Colors.redAccent,
                        ),
                        label: const Text(
                          'Stop',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                ),

              // Custom Input bar
              _buildInputBar(isDark),
            ],
          ),
        ],
      ),
    ),
    );
  }

  Widget _buildDrawer(BuildContext context, bool isDark) {
    final drawerBg = isDark ? const Color(0xFF0B0F19) : const Color(0xFFF8FAFC);
    final textStyle = TextStyle(
      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
      fontWeight: FontWeight.w600,
      fontSize: 13.5,
    );
    final headerStyle = TextStyle(
      color: isDark ? Colors.white : const Color(0xFF1E293B),
      fontSize: 17,
      fontWeight: FontWeight.w900,
      letterSpacing: -0.5,
    );

    return Drawer(
      backgroundColor: drawerBg,
      child: Column(
        children: [
          // Drawer Header
          Container(
            padding: const EdgeInsets.only(
              top: 60,
              bottom: 20,
              left: 24,
              right: 24,
            ),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Icon(
                  Icons.smart_toy_rounded,
                  color: _zaxMode.color,
                  size: 26,
                ),
                const SizedBox(width: 12),
                Text('ZAX', style: headerStyle.copyWith(letterSpacing: 4)),
              ],
            ),
          ),

          // New Chat Button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: _zaxMode.color,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: _zaxMode.color.withOpacity(0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    Navigator.pop(context); // Close drawer
                    _startNewChat();
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.add_comment_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'New Chat',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          const Divider(indent: 16, endIndent: 16, height: 20),

          // Section CHAT HISTORY
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'CHAT HISTORY',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: _zaxMode.color,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),

          // Chat Sessions List
          Expanded(
            child: FutureBuilder<List<ChatSession>>(
              future: ChatHistoryService.loadSessions(),
              builder: (context, snapshot) {
                if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  return Center(
                    child: Text(
                      'No recent chats',
                      style: TextStyle(
                        color: isDark ? Colors.grey[800] : Colors.grey[400],
                        fontSize: 12,
                      ),
                    ),
                  );
                }

                final sessions = snapshot.data!;
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: sessions.length,
                  itemBuilder: (context, index) {
                    final session = sessions[index];
                    final isCurrent = session.id == _sessionId;

                    return Container(
                      margin: const EdgeInsets.symmetric(
                        vertical: 2,
                        horizontal: 8,
                      ),
                      decoration: BoxDecoration(
                        color: isCurrent
                            ? _zaxMode.color.withOpacity(0.08)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        border: isCurrent
                            ? Border.all(
                                color: _zaxMode.color.withOpacity(0.15),
                              )
                            : null,
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 0,
                        ),
                        dense: true,
                        leading: Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 15,
                          color: isCurrent
                              ? _zaxMode.color
                              : (isDark ? Colors.grey[600] : Colors.grey[500]),
                        ),
                        title: Text(
                          session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textStyle.copyWith(
                            fontWeight: isCurrent
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: isCurrent
                                ? (isDark
                                      ? Colors.white
                                      : const Color(0xFF1E293B))
                                : null,
                          ),
                        ),
                        trailing: IconButton(
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            size: 16,
                            color: Colors.redAccent.withOpacity(0.7),
                          ),
                          onPressed: () async {
                            await ChatHistoryService.deleteSession(session.id);
                            if (isCurrent) {
                              _startNewChat();
                            }
                            (context as Element)
                                .markNeedsBuild(); // Re-trigger build refresh
                          },
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          _loadChatSession(session);
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),

          const Divider(indent: 16, endIndent: 16, height: 20),

          // Section TASKS & SETTINGS
          ListTile(
            horizontalTitleGap: 8,
            leading: Icon(
              Icons.history_rounded,
              color: isDark ? Colors.grey[400] : Colors.grey[600],
              size: 20,
            ),
            title: Text('Task History', style: textStyle),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const TaskHistoryScreen()),
              );
            },
          ),
          for (final item in <(IconData, String, Widget Function())>[
            (Icons.checklist_rounded, 'Tasks & Reminders', () => const TasksScreen()),
            (Icons.psychology_alt_rounded, 'Memory', () => const MemoryScreen()),
            (Icons.sticky_note_2_outlined, 'Notes & Files', () => const NotesScreen()),
            (
              Icons.hub_rounded,
              'Mode Providers (4 per mode)',
              () => ModeProvidersScreen(aiService: _aiService),
            ),
          ])
            ListTile(
              horizontalTitleGap: 8,
              leading: Icon(
                item.$1,
                color: isDark ? Colors.grey[400] : Colors.grey[600],
                size: 20,
              ),
              title: Text(item.$2, style: textStyle),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => item.$3()),
                );
              },
            ),
          ListTile(
            horizontalTitleGap: 8,
            leading: Icon(
              Icons.settings_rounded,
              color: isDark ? Colors.grey[400] : Colors.grey[600],
              size: 20,
            ),
            title: Text('Settings', style: textStyle),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(
                    aiService: _aiService,
                    shizukuService: _actionHandler.shizuku,
                    screenAutomationService: _actionHandler.screenAutomation,
                    telegramService: _telegramService,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildBackgroundGlows(bool isDark) {
    final accent = _zaxMode.color;
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned(
            top: -150,
            left: -50,
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [accent.withOpacity(0.22), accent.withOpacity(0)],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 50,
            right: -100,
            child: Container(
              width: 350,
              height: 350,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [accent.withOpacity(0.14), accent.withOpacity(0)],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  ThemeData _hudTheme(BuildContext context) {
    final accent = _zaxMode.color;
    return Theme.of(context).copyWith(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF04070B),
      primaryColor: accent,
      colorScheme: ColorScheme.dark(
        primary: accent,
        onPrimary: Colors.black,
        secondary: accent,
        surface: const Color(0xFF0E141B),
        onSurface: Colors.white,
        error: Colors.redAccent,
      ),
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        iconTheme: IconThemeData(color: Colors.white),
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
    );
  }

  /// The big glowing Zax core. It shrinks once a chat has started or while
  /// the keyboard is open, so it never gets in the way.
  Widget _buildCore() {
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    final compact = _messages.isNotEmpty || keyboardOpen;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      height: compact ? 96 : 230,
      child: Center(
        child: ZaxCore(
          color: _zaxMode.color,
          active: _isLoading || _isListening,
          lite: compact,
        ),
      ),
    );
  }

  /// The 4 mode buttons: Normal, Study, Image, Code.
  Widget _buildZaxModeChips() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Row(
        children: ZaxMode.values.map((m) {
          final selected = m == _zaxMode;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _zaxMode = m);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: selected
                      ? m.color.withOpacity(0.18)
                      : Colors.white.withOpacity(0.04),
                  border: Border.all(
                    color: selected
                        ? m.color
                        : Colors.white.withOpacity(0.10),
                    width: selected ? 1.4 : 1,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: m.color.withOpacity(0.35),
                            blurRadius: 12,
                          ),
                        ]
                      : null,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      m.icon,
                      size: 18,
                      color: selected ? m.color : Colors.white54,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      m.label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: selected ? m.color : Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildModeSelector(bool isDark) {
    final activeBg = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: activeBg,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: Colors.white.withOpacity(0.06),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildModeButton(
              'chat',
              'Chat',
              Icons.chat_bubble_outline_rounded,
              isDark,
            ),
            _buildModeButton(
              'agent',
              'Agent',
              Icons.smart_toy_outlined,
              isDark,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeButton(
    String modeId,
    String label,
    IconData icon,
    bool isDark,
  ) {
    final isSelected = _mode == modeId;

    return GestureDetector(
      onTap: () {
        setState(() {
          _mode = modeId;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          color: isSelected
              ? _zaxMode.color
              : Colors.transparent,
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: _zaxMode.color.withOpacity(0.20),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected
                  ? Colors.white
                  : (isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF475569)),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? Colors.white
                    : (isDark
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF475569)),
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    final time = DateTime.now();
    String timeGreeting = 'Hello';
    if (time.hour >= 5 && time.hour < 12) {
      timeGreeting = 'Good morning. Zax is online.';
    } else if (time.hour >= 12 && time.hour < 17) {
      timeGreeting = 'Good afternoon. Zax is online.';
    } else if (time.hour >= 17 && time.hour < 22) {
      timeGreeting = 'Good evening. Zax is online.';
    } else {
      timeGreeting = 'Still up? Zax is online.';
    }

    final suggestions = _mode == 'chat'
        ? _zaxMode.suggestions
        : [
            'Open YouTube and search for cats',
            'Call Mom',
            'Set volume to 80%',
            'What\'s on my screen?',
          ];

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    timeGreeting,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w300,
                      color: isDark
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF64748B),
                      letterSpacing: -1.5,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _zaxMode.tagline,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w600,
                      color: _zaxMode.color,
                      letterSpacing: -1.5,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 48),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'SUGGESTIONS',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF475569),
                  letterSpacing: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: suggestions.length,
                itemBuilder: (context, index) {
                  final suggestion = suggestions[index];
                  return Container(
                    margin: const EdgeInsets.only(right: 12),
                    child: InkWell(
                      onTap: () => _sendMessage(suggestion),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF151D30)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isDark
                                ? const Color(0xFF243049).withOpacity(0.4)
                                : const Color(0xFFE2E8F0),
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(
                                isDark ? 0.1 : 0.02,
                              ),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Text(
                            suggestion,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? const Color(0xFFF8FAFC)
                                  : const Color(0xFF1E293B),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Row(
        children: [
          // Glowing Voice Mic button
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isListening
                  ? Colors.redAccent
                  : const Color(0xFF0E141B),
              border: Border.all(
                color: _isListening
                    ? Colors.redAccent
                    : Colors.white.withOpacity(0.08),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(isDark ? 0.2 : 0.03),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
                if (_isListening)
                  BoxShadow(
                    color: Colors.redAccent.withOpacity(0.4),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
              ],
            ),
            child: IconButton(
              icon: Icon(
                _isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
                color: _isListening
                    ? Colors.white
                    : _zaxMode.color,
              ),
              onPressed: _isLoading ? null : _toggleVoice,
            ),
          ),
          const SizedBox(width: 10),

          // Custom Text input container
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0E141B),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Colors.white.withOpacity(0.08),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(isDark ? 0.2 : 0.03),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: _isListening
                            ? 'Listening...'
                            : _zaxMode.hint,
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.grey[600] : Colors.grey[400],
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        border: InputBorder.none,
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: _isLoading
                          ? null
                          : (text) => _sendMessage(text),
                    ),
                  ),

                  // Solid Send button
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _zaxMode.color,
                    ),
                    child: IconButton(
                      icon: const Icon(
                        Icons.send_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
                      onPressed: _isLoading
                          ? null
                          : () => _sendMessage(_textController.text),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
