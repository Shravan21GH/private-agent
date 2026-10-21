import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/zax_identity.dart';
import '../models/agent_action.dart';
import 'memory_store.dart';
import 'chat_history_service.dart';

class AiResponse {
  final String content;
  final int totalTokens;
  AiResponse(this.content, this.totalTokens);
}

/// Provider settings for one Zax mode (for example Study or Programming).
/// A mode that has its own settings uses them for its chat replies.
class ModeProvider {
  final String apiKey;
  final String baseUrl;
  final String model;
  const ModeProvider({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
  });

  bool get isConfigured =>
      apiKey.isNotEmpty && baseUrl.isNotEmpty && model.isNotEmpty;
}

class AiService {
  static const String _defaultBaseUrl = 'https://api.deepseek.com';
  static const String _defaultModel = 'deepseek-chat';
  static const String nvidiaBaseUrl = 'https://integrate.api.nvidia.com/v1';
  static const String nvidiaDefaultModel = 'z-ai/glm-5.2';

  /// Free, general-purpose chat endpoints verified in NVIDIA's NIM catalog.
  /// The live /models response is intersected with this list so unavailable or
  /// non-chat models never appear in PrivateAgent's NVIDIA model picker.
  static const List<String> nvidiaFreeChatModels = [
    'z-ai/glm-5.2',
    'nvidia/nemotron-3-nano-30b-a3b',
    'nvidia/nemotron-3-super-120b-a12b',
    'nvidia/nemotron-3-ultra-550b-a55b',
    'nvidia/nvidia-nemotron-nano-9b-v2',
    'openai/gpt-oss-20b',
    'openai/gpt-oss-120b',
    'meta/llama-3.3-70b-instruct',
    'meta/llama-3.2-3b-instruct',
    'meta/llama-3.1-8b-instruct',
    'meta/llama-3.1-70b-instruct',
    'mistralai/mistral-nemotron',
    'deepseek-ai/deepseek-v4-flash',
    'deepseek-ai/deepseek-v4-pro',
  ];

  static bool isNvidiaBaseUrl(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    return uri?.host.toLowerCase() == 'integrate.api.nvidia.com';
  }

  static List<String> filterNvidiaFreeModels(Iterable<String> models) {
    final availableModels = models.toSet();
    return nvidiaFreeChatModels
        .where(availableModels.contains)
        .toList(growable: false);
  }

  String? _apiKey;
  String _baseUrl = _defaultBaseUrl;
  String _model = _defaultModel;
  int _maxSteps = 15;
  bool _disableMaxSteps = false;
  double _temperature = 1.0;
  int _maxTokens = 1024;
  bool _useScreenCompression = true;
  bool _useSystemPrompt = true;
  bool _useChatHistoryContext = false;
  final List<Map<String, String>> _conversationHistory = [];

  /// Extra instructions for the current Zax mode (Study / Programming).
  /// Only added to normal chat replies, never to phone-control (agent) prompts.
  String modeInstruction = '';

  /// The active Zax mode: 'normal', 'study', 'programming' or 'image'.
  /// Set by the home screen before each message.
  String activeMode = 'normal';

  /// Modes that can have their own provider. Image mode uses Pollinations
  /// and has no AI chat provider.
  static const List<String> providerModes = ['normal', 'study', 'programming', 'agent'];

  final Map<String, ModeProvider> _modeProviders = {};
  static const int providersPerMode = 4;
  String _providerKey(String mode, int slot) => 'mode_${mode}_provider_${slot}';
  ModeProvider? modeProviderForSlot(String mode, int slot) =>
      _modeProviders['${mode}_$slot'] ?? (slot == 1 ? _modeProviders[mode] : null);
  List<ModeProvider?> providersForMode(String mode) =>
      List<ModeProvider?>.generate(providersPerMode, (i) => modeProviderForSlot(mode, i + 1));

  /// Ordered provider chain. The first configured provider is preferred; later
  /// entries are available as fallbacks when a request fails before a response.
  List<ModeProvider> providerChainFor(String mode) => providersForMode(mode)
      .whereType<ModeProvider>().where((p) => p.isConfigured).toList();

  List<ModeProvider> _configuredCandidates({required bool isAgentMode}) {
    final candidates = <ModeProvider>[];
    candidates.addAll(providerChainFor(isAgentMode ? 'agent' : activeMode));
    if (_apiKey != null && _apiKey!.isNotEmpty && _baseUrl.isNotEmpty && _model.isNotEmpty) {
      final main = ModeProvider(apiKey: _apiKey!, baseUrl: _baseUrl, model: _model);
      if (!candidates.any((p) => p.apiKey == main.apiKey && p.baseUrl == main.baseUrl && p.model == main.model)) {
        candidates.add(main);
      }
    }
    return candidates;
  }

  /// First configured provider for legacy callers. Request methods use the full
  /// ordered chain and fall back to the main Settings provider.
  ModeProvider? get _activeOverride {
    final chain = providerChainFor(activeMode);
    return chain.isEmpty ? null : chain.first;
  }

  static const String _systemPrompt = '''
You are Zax, a helpful AI assistant that controls an Android phone. You can perform device actions and also have normal conversations.

When the user wants to perform a device action, you MUST respond with ONLY a JSON object (no markdown, no code fences, no extra text) in this exact format:
{"action": "action_name", "params": {"key": "value"}, "response": "What you say to the user"}

Available actions and their params:

SIMPLE ACTIONS (single step only):
- open_camera: {} - Opens the system camera app when the user asks to open/use the camera; it does not silently capture or upload photos
- open_app: {"app_name": "YouTube"} - ONLY use this when the user JUST wants to open an app and nothing else
- make_call: {"contact_name": "Mom"} OR {"phone_number": "1234567890"} - Makes a phone call
- send_sms: {"contact_name": "John", "message": "Hello"} OR {"phone_number": "123", "message": "Hi"} - Sends SMS
- search_contact: {"query": "John"} - Searches contacts
- set_alarm: {"hour": 7, "minute": 30, "label": "Wake up"} - Sets an alarm
- set_volume: {"level": 50} - Sets volume (0-100)
- set_brightness: {"level": 50} - Sets brightness (0-100)
- read_screen: {} - Read what's currently on the screen
- press_back: {} - Press the back button

MULTI-STEP TASK (for anything that requires more than one action):
- execute_task: {"goal": "description of the full task"} - Automatically reads screen, taps, scrolls, types step by step

CRITICAL RULES:
1. If the user request contains "and" or involves MULTIPLE steps (open + search, open + send, open + find, etc.), you MUST use execute_task. NEVER use open_app for these.
2. execute_task handles everything: opening apps, finding elements, clicking, typing, scrolling.

Examples of when to use execute_task:
- "Create a new alarm for 7 AM" → execute_task with goal "Create a new alarm for 7 AM"
- "Go to YouTube and search for cats" → execute_task
- "Open WhatsApp and send hello to John" → execute_task
- "Open Settings and turn on WiFi" → execute_task
- "Search for restaurants on Google Maps" → execute_task

Examples of when to use open_app:
- "Open YouTube" → open_app (just opening, no further action)
- "Open Settings" → open_app (just opening)

For normal conversation (questions, chat, info requests), just respond with plain text naturally.
''';

  static const String _chatSystemPrompt = '''
You are Zax, a personal assistant with a natural, warm, consistent personality.
Sound like a capable, friendly companion—not a generic chatbot or customer-support script. Be conversational and relaxed, remember relevant context supplied in this prompt, and avoid repetitive disclaimers or fake enthusiasm. Keep simple answers concise; give full detail when asked. Be honest about uncertainty and never claim to have completed an action you did not execute and verify. This chat mode can answer, explain, brainstorm, write, and converse; device actions must use Agent mode.
''';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _apiKey = prefs.getString('api_key');
    _baseUrl = prefs.getString('api_base_url') ?? _defaultBaseUrl;
    _model = prefs.getString('api_model') ?? _defaultModel;
    _maxSteps = prefs.getInt('api_max_steps') ?? 15;
    _disableMaxSteps = prefs.getBool('api_disable_max_steps') ?? false;
    _temperature = prefs.getDouble('api_temperature') ?? 1.0;
    _maxTokens = prefs.getInt('api_max_tokens') ?? 1024;
    _useScreenCompression = prefs.getBool('api_use_screen_compression') ?? true;
    _useSystemPrompt = prefs.getBool('api_use_system_prompt') ?? true;
    _useChatHistoryContext = prefs.getBool('zax_use_chat_history_context') ?? false;
    for (final mode in providerModes) {
      // Migrate the legacy single provider to slot 1 without losing settings.
      final oldKey = prefs.getString('mode_${mode}_api_key') ?? '';
      final oldUrl = prefs.getString('mode_${mode}_base_url') ?? '';
      final oldModel = prefs.getString('mode_${mode}_model') ?? '';
      if (oldKey.isNotEmpty || oldUrl.isNotEmpty || oldModel.isNotEmpty) {
        _modeProviders[mode] = ModeProvider(apiKey: oldKey, baseUrl: oldUrl, model: oldModel);
      }
      for (var slot = 1; slot <= providersPerMode; slot++) {
        final key = prefs.getString('${_providerKey(mode, slot)}_api_key') ?? '';
        final url = prefs.getString('${_providerKey(mode, slot)}_base_url') ?? '';
        final model = prefs.getString('${_providerKey(mode, slot)}_model') ?? '';
        if (key.isNotEmpty || url.isNotEmpty || model.isNotEmpty) {
          _modeProviders['${mode}_$slot'] = ModeProvider(apiKey: key, baseUrl: url, model: model);
        } else if (slot == 1 && _modeProviders.containsKey(mode)) {
          _modeProviders['${mode}_$slot'] = _modeProviders[mode];
        }
      }
    }
  }

  ModeProvider? modeProviderFor(String mode) {
    final chain = providerChainFor(mode);
    return chain.isEmpty ? _modeProviders[mode] : chain.first;
  }

  Future<void> saveModeProvider(
    String mode, {
    required String apiKey,
    required String baseUrl,
    required String model,
    int slot = 1,
  }) async {
    if (slot < 1 || slot > providersPerMode) throw ArgumentError('Provider slot must be 1-4');
    var key = apiKey.trim();
    if (key.toLowerCase().startsWith('bearer ')) key = key.substring(7).trim();
    final provider = ModeProvider(apiKey: key, baseUrl: baseUrl.trim(), model: model.trim());
    final prefs = await SharedPreferences.getInstance();
    final prefix = _providerKey(mode, slot);
    await prefs.setString('${prefix}_api_key', provider.apiKey);
    await prefs.setString('${prefix}_base_url', provider.baseUrl);
    await prefs.setString('${prefix}_model', provider.model);
    _modeProviders['${mode}_$slot'] = provider;
    if (slot == 1) _modeProviders[mode] = provider;
  }

  Future<void> clearModeProvider(String mode, {int slot = 1}) async {
    final prefs = await SharedPreferences.getInstance();
    final prefix = _providerKey(mode, slot);
    await prefs.remove('${prefix}_api_key');
    await prefs.remove('${prefix}_base_url');
    await prefs.remove('${prefix}_model');
    _modeProviders.remove('${mode}_$slot');
    if (slot == 1) {
      _modeProviders.remove(mode);
      await prefs.remove('mode_${mode}_api_key');
      await prefs.remove('mode_${mode}_base_url');
      await prefs.remove('mode_${mode}_model');
    }
  }

  Future<void> saveSettings({
    required String apiKey,
    String? baseUrl,
    String? model,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    // Clean up the API key in case the user pasted "Bearer sk-..."
    String cleanApiKey = apiKey.trim();
    if (cleanApiKey.toLowerCase().startsWith('bearer ')) {
      cleanApiKey = cleanApiKey.substring(7).trim();
    }

    _apiKey = cleanApiKey;
    await prefs.setString('api_key', cleanApiKey);

    if (baseUrl != null && baseUrl.isNotEmpty) {
      _baseUrl = baseUrl;
      await prefs.setString('api_base_url', baseUrl);
    }
    if (model != null && model.isNotEmpty) {
      _model = model;
      await prefs.setString('api_model', model);
    }
  }

  Future<void> saveMaxSteps(int steps) async {
    final prefs = await SharedPreferences.getInstance();
    _maxSteps = steps;
    await prefs.setInt('api_max_steps', steps);
  }

  Future<void> saveDisableMaxSteps(bool disable) async {
    final prefs = await SharedPreferences.getInstance();
    _disableMaxSteps = disable;
    await prefs.setBool('api_disable_max_steps', disable);
  }

  Future<void> saveAdvancedSettings({
    required double temperature,
    required int maxTokens,
    required bool useScreenCompression,
    required bool useSystemPrompt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    _temperature = temperature;
    _maxTokens = maxTokens;
    _useScreenCompression = useScreenCompression;
    _useSystemPrompt = useSystemPrompt;
    await prefs.setDouble('api_temperature', temperature);
    await prefs.setInt('api_max_tokens', maxTokens);
    await prefs.setBool('api_use_screen_compression', useScreenCompression);
    await prefs.setBool('api_use_system_prompt', useSystemPrompt);
  }

  bool get isConfigured => _apiKey != null && _apiKey!.isNotEmpty;
  String get baseUrl => _baseUrl;
  String get model => _model;
  String get apiKey => _apiKey ?? '';
  /// The agent can never run more steps than this, whatever the settings say.
  static const int hardMaxSteps = 25;

  int get maxSteps =>
      (_disableMaxSteps ? hardMaxSteps : _maxSteps).clamp(1, hardMaxSteps).toInt();
  int get rawMaxSteps => _maxSteps; // For the slider UI
  bool get disableMaxSteps => _disableMaxSteps;
  double get temperature => _temperature;
  int get maxTokens => _maxTokens;
  bool get useScreenCompression => _useScreenCompression;
  bool get useSystemPrompt => _useSystemPrompt;
  bool get useChatHistoryContext => _useChatHistoryContext;
  Future<void> setUseChatHistoryContext(bool enabled) async {
    _useChatHistoryContext = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('zax_use_chat_history_context', enabled);
  }

  int get _effectiveMaxTokens => _maxTokensFor(_baseUrl, _model);

  int _maxTokensFor(String baseUrl, String model) {
    // GLM is a reasoning model. With the app's 1,024-token default it can
    // consume the whole budget reasoning and finish without visible content.
    if (isNvidiaBaseUrl(baseUrl) &&
        model == nvidiaDefaultModel &&
        _maxTokens < 4096) {
      return 4096;
    }
    return _maxTokens;
  }

  void clearHistory() {
    _conversationHistory.clear();
  }

  void addHistoryMessage(String role, String content) {
    _conversationHistory.add({'role': role, 'content': content});
    if (_conversationHistory.length > 20) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 20);
    }
  }

  /// Send a message to the AI and get a response.
  Future<String> sendMessage(String message, {bool isAgentMode = true}) async {
    // Chat replies use the active mode's own provider if it has one.
    // Phone-control (agent) tasks always use the main provider.
    final candidates = _configuredCandidates(isAgentMode: isAgentMode);
    if (candidates.isEmpty) {
      throw Exception('No API provider is configured. Add a provider in Zax Settings.');
    }
    var selectedProvider = candidates.first;
    var apiKey = selectedProvider.apiKey;
    var baseUrl = selectedProvider.baseUrl;
    var model = selectedProvider.model;

    // Add ONLY the text to the persistent conversation history to save tokens.
    _conversationHistory.add({'role': 'user', 'content': message});

    // Keep conversation history manageable (last 20 messages)
    if (_conversationHistory.length > 20) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 20);
    }

    try {
      // Build the prompt including system instructions
      final systemPrompt = isAgentMode
          ? _systemPrompt
          : (modeInstruction.isEmpty
                ? _chatSystemPrompt
                : '$_chatSystemPrompt\n$modeInstruction');
      var fullSystemPrompt = '${ZaxIdentity.statement}\n$systemPrompt';
      if (!isAgentMode) {
        final remembered = await MemoryStore.instance.contextFor(message);
        if (remembered.isNotEmpty) {
          fullSystemPrompt = '$fullSystemPrompt\n\n$remembered';
        }
        if (_useChatHistoryContext) {
          final priorChats = await ChatHistoryService.searchAcrossChats(message);
          if (priorChats.isNotEmpty) {
            fullSystemPrompt = '$fullSystemPrompt\n\n$priorChats';
          }
        }
      }
      final messages = [
        if (_useSystemPrompt) {'role': 'system', 'content': fullSystemPrompt},
        ..._conversationHistory,
      ];

      http.Response? response;
      final providerErrors = <String>[];
      for (final candidate in candidates) {
        apiKey = candidate.apiKey;
        baseUrl = candidate.baseUrl;
        model = candidate.model;
        final requestUrl = baseUrl.endsWith('/chat/completions')
            ? baseUrl
            : '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';
        final requestBody = jsonEncode({
          'model': model,
          'messages': messages,
          'temperature': _temperature,
          'max_tokens': _maxTokensFor(baseUrl, model),
        });
        developer.log('API request to $requestUrl (model: $model)', name: 'AiService');
        try {
          final attempt = await http.post(
            Uri.parse(requestUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
              'HTTP-Referer': 'https://github.com/orailnoor/private-agent',
              'X-Title': 'Zax',
            },
            body: requestBody,
          ).timeout(const Duration(seconds: 35));
          developer.log('API response status: ${attempt.statusCode}', name: 'AiService');
          if (attempt.statusCode == 200) {
            response = attempt;
            break;
          }
          final bodyPreview = attempt.body.length > 180 ? attempt.body.substring(0, 180) : attempt.body;
          providerErrors.add('$model (${attempt.statusCode}): $bodyPreview');
        } catch (e) {
          providerErrors.add('$model: $e');
        }
      }
      if (response == null) {
        throw Exception('All configured providers failed. ${providerErrors.join(' | ')}');
      }


      if (response.statusCode != 200) {
        String errorMessage = response.body;
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) {
            if (decoded['error'] is Map<String, dynamic>) {
              errorMessage =
                  decoded['error']['message']?.toString() ?? response.body;
            } else if (decoded['error'] is String) {
              errorMessage = decoded['error'];
            }
          }
        } catch (_) {
          // ignore parsing errors, use raw body
        }
        throw Exception('API error (${response.statusCode}): $errorMessage');
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic> || !data.containsKey('choices')) {
        throw Exception('Unexpected API response format: $data');
      }

      String assistantMessage =
          data['choices'][0]['message']['content'] as String;

      // Strip <think> blocks commonly produced by reasoning models
      assistantMessage = assistantMessage
          .replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '')
          .trim();

      if (assistantMessage.trim().isEmpty) {
        throw Exception(
          'API returned an empty response. This may be due to rate limits or API instability.',
        );
      }

      _conversationHistory.add({
        'role': 'assistant',
        'content': assistantMessage,
      });

      return assistantMessage;
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Network error: $e');
    }
  }

  /// Send a message and stream the response chunk-by-chunk.
  Stream<String> sendMessageStream(
    String message, {
    bool isAgentMode = true,
  }) async* {
    // Use four mode-specific providers in priority order, then the main
    // Settings provider as a final fallback. Agent mode has its own chain.
    final candidates = <ModeProvider>[];
    final modeKey = isAgentMode ? 'agent' : activeMode;
    candidates.addAll(providerChainFor(modeKey));
    if (_apiKey != null && _apiKey!.isNotEmpty && _baseUrl.isNotEmpty && _model.isNotEmpty) {
      final main = ModeProvider(apiKey: _apiKey!, baseUrl: _baseUrl, model: _model);
      if (!candidates.any((p) => p.apiKey == main.apiKey && p.baseUrl == main.baseUrl && p.model == main.model)) {
        candidates.add(main);
      }
    }
    if (candidates.isEmpty) {
      throw Exception('No API provider is configured. Open Settings and add a provider.');
    }

    _conversationHistory.add({'role': 'user', 'content': message});

    if (_conversationHistory.length > 20) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 20);
    }

    try {
      final systemPrompt = isAgentMode
          ? _systemPrompt
          : (modeInstruction.isEmpty
                ? _chatSystemPrompt
                : '$_chatSystemPrompt\n$modeInstruction');
      var fullSystemPrompt = '${ZaxIdentity.statement}\n$systemPrompt';
      if (!isAgentMode) {
        final remembered = await MemoryStore.instance.contextFor(message);
        if (remembered.isNotEmpty) {
          fullSystemPrompt = '$fullSystemPrompt\n\n$remembered';
        }
        if (_useChatHistoryContext) {
          final priorChats = await ChatHistoryService.searchAcrossChats(message);
          if (priorChats.isNotEmpty) {
            fullSystemPrompt = '$fullSystemPrompt\n\n$priorChats';
          }
        }
      }
      final messages = [
        if (_useSystemPrompt) {'role': 'system', 'content': fullSystemPrompt},
        ..._conversationHistory,
      ];

      String requestUrl = '';
      String apiKey = '';
      String baseUrl = '';
      String model = '';
      http.Client? client;
      http.StreamedResponse? response;
      final providerErrors = <String>[];
      // Fail over only before any answer has been streamed, avoiding duplicated
      // partial answers. Simple requests still start with the first provider.
      for (final candidate in candidates) {
        apiKey = candidate.apiKey;
        baseUrl = candidate.baseUrl;
        model = candidate.model;
        requestUrl = baseUrl.endsWith('/chat/completions')
            ? baseUrl
            : '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';
        final attemptClient = http.Client();
        final request = http.Request('POST', Uri.parse(requestUrl));
        request.headers.addAll({
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
          'HTTP-Referer': 'https://github.com/orailnoor/private-agent',
          'X-Title': 'Zax',
        });
        request.body = jsonEncode({
          'model': model,
          'messages': messages,
          'temperature': _temperature,
          'max_tokens': _maxTokensFor(baseUrl, model),
          'stream': true,
        });
        try {
          final attempt = await attemptClient.send(request).timeout(const Duration(seconds: 25));
          if (attempt.statusCode == 200) {
            client = attemptClient;
            response = attempt;
            break;
          }
          final body = await attempt.stream.bytesToString();
          providerErrors.add('$model (${attempt.statusCode}): ${body.length > 180 ? body.substring(0, 180) : body}');
          attemptClient.close();
        } catch (e) {
          providerErrors.add('$model: $e');
          attemptClient.close();
        }
      }
      if (response == null || client == null) {
        throw Exception('All configured providers failed. ${providerErrors.join(' | ')}');
      }

      final accumulatedContent = StringBuffer();
      bool inThinkBlock = false;

      // Listen to response stream
      final lineStream = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lineStream) {
        final trimmedLine = line.trim();
        if (trimmedLine.isEmpty) continue;
        if (trimmedLine.startsWith('data:')) {
          final dataStr = trimmedLine.substring(5).trim();
          if (dataStr == '[DONE]') break;
          try {
            final json = jsonDecode(dataStr);
            if (json is Map && json['choices'] is List) {
              final choices = json['choices'] as List;
              if (choices.isNotEmpty) {
                final choice = choices[0];
                if (choice is! Map) continue;
                final rawDelta = choice['delta'];
                final delta = rawDelta is Map ? rawDelta : const {};
                final rawContent = delta['content'];
                if (rawContent is String && rawContent.isNotEmpty) {
                  final content = rawContent;
                  accumulatedContent.write(content);

                  // Handle <think> block stripping on the fly for better stream styling
                  if (content.contains('<think>')) {
                    inThinkBlock = true;
                    // If there is text before <think>, yield it
                    final parts = content.split('<think>');
                    if (parts[0].isNotEmpty) {
                      yield parts[0];
                    }
                  } else if (content.contains('</think>')) {
                    inThinkBlock = false;
                    // If there is text after </think>, yield it
                    final parts = content.split('</think>');
                    if (parts.length > 1 && parts[1].isNotEmpty) {
                      yield parts[1];
                    }
                  } else if (!inThinkBlock) {
                    yield content;
                  }
                }
                if (choice['finish_reason'] != null) break;
              }
            }
          } catch (_) {
            // Ignore incomplete chunks
          }
        }
      }

      client.close();

      // Clean up final accumulated response and add to history
      String finalResponse = accumulatedContent.toString().trim();
      finalResponse = finalResponse
          .replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '')
          .trim();

      if (finalResponse.isEmpty) {
        throw Exception(
          'The model finished without a visible answer. Increase Max Tokens '
          'or try another NVIDIA model.',
        );
      }
      _conversationHistory.add({'role': 'assistant', 'content': finalResponse});
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Network error: $e');
    }
  }

  /// Send a task execution message — no conversation history, low temperature, limited tokens.
  /// This is much faster and cheaper than sendMessage.
  Future<AiResponse> sendTaskMessage(String systemPrompt, String prompt) async {
    final candidates = _configuredCandidates(isAgentMode: true);
    if (candidates.isEmpty) {
      throw Exception('No API provider is configured. Open Settings and add a provider.');
    }
    final messages = [
      if (_useSystemPrompt) {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': prompt},
    ];
    final errors = <String>[];
    for (final provider in candidates) {
      final requestUrl = provider.baseUrl.endsWith('/chat/completions')
          ? provider.baseUrl
          : '${provider.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';
      try {
        final response = await http.post(
          Uri.parse(requestUrl),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${provider.apiKey}',
            'HTTP-Referer': 'https://github.com/orailnoor/private-agent',
            'X-Title': 'Zax',
          },
          body: jsonEncode({
            'model': provider.model,
            'messages': messages,
            'temperature': _temperature,
            'max_tokens': _maxTokensFor(provider.baseUrl, provider.model),
          }),
        ).timeout(const Duration(seconds: 35));
        if (response.statusCode != 200) {
          final body = response.body.length > 180 ? response.body.substring(0, 180) : response.body;
          errors.add('${provider.model} (${response.statusCode}): $body');
          continue;
        }
        final data = jsonDecode(response.body);
        if (data is! Map<String, dynamic> || data['choices'] is! List || (data['choices'] as List).isEmpty) {
          errors.add('${provider.model}: unexpected API response format');
          continue;
        }
        final choice = (data['choices'] as List).first;
        if (choice is! Map || choice['message'] is! Map) {
          errors.add('${provider.model}: missing message content');
          continue;
        }
        var content = (choice['message'] as Map)['content']?.toString() ?? '';
        content = content.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '').trim();
        if (content.isEmpty) {
          errors.add('${provider.model}: empty response');
          continue;
        }
        final usage = data['usage'];
        final tokens = usage is Map && usage['total_tokens'] is int ? usage['total_tokens'] as int : 0;
        return AiResponse(content, tokens);
      } catch (e) {
        errors.add('${provider.model}: $e');
      }
    }
    throw Exception('All Agent providers failed. ${errors.join(' | ')}');
  }

  /// Parse the AI response to check if it's an action or plain text
  AgentAction? parseAction(String response) {
    // Try to parse as JSON action
    try {
      final trimmed = response.trim();
      // Handle if the response is wrapped in code fences
      String jsonStr = trimmed;
      if (trimmed.startsWith('```')) {
        final lines = trimmed.split('\n');
        lines.removeAt(0); // Remove opening fence
        if (lines.isNotEmpty && lines.last.trim() == '```') {
          lines.removeLast(); // Remove closing fence
        }
        jsonStr = lines.join('\n').trim();
      }

      // If it looks like JSON but is missing a closing brace (common with some local models)
      if (jsonStr.startsWith('{') && !jsonStr.endsWith('}')) {
        jsonStr += '\n}';
      }

      if (jsonStr.startsWith('{') && jsonStr.contains('"action"')) {
        try {
          final json = jsonDecode(jsonStr) as Map<String, dynamic>;
          if (json.containsKey('action')) {
            return AgentAction.fromJson(json);
          }
        } catch (e) {
          // If it still fails, it might be deeply truncated, try adding another brace
          if (e.toString().contains('Unexpected end of input')) {
            jsonStr += '\n}';
            final json = jsonDecode(jsonStr) as Map<String, dynamic>;
            if (json.containsKey('action')) {
              return AgentAction.fromJson(json);
            }
          }
        }
      }
    } catch (_) {
      // Not JSON, it's plain text conversation
    }
    return null;
  }

  /// Fetches available models from the provider's /models endpoint
  Future<List<String>> fetchAvailableModels(
    String baseUrl,
    String apiKey,
  ) async {
    try {
      String cleanBaseUrl = baseUrl;
      // Many providers host it at /models, but some require the base URL without /chat/completions logic
      if (cleanBaseUrl.endsWith('/chat/completions')) {
        cleanBaseUrl = cleanBaseUrl.replaceAll('/chat/completions', '');
      }

      final response = await http.get(
        Uri.parse('$cleanBaseUrl/models'),
        headers: {'Authorization': 'Bearer $apiKey'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        List<String> models;
        if (data is Map && data.containsKey('data')) {
          final modelsList = data['data'] as List;
          models = modelsList.map((m) => m['id'].toString()).toList();
        } else if (data is List) {
          models = data.map((m) => m['id'].toString()).toList();
        } else {
          return [];
        }

        if (isNvidiaBaseUrl(cleanBaseUrl)) {
          return filterNvidiaFreeModels(models);
        }
        models.sort();
        return models;
      }
      return [];
    } catch (e) {
      print('Error fetching models: $e');
      return [];
    }
  }
}
