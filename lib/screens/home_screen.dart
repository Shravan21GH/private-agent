import 'dart:async';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/chat_message.dart';
import '../services/ai_service.dart';
import '../services/chat_history_service.dart';
import '../services/notification_service.dart';
import '../widgets/message_bubble.dart';

class PendingAttachment {
  final String name;
  final String path;
  final String kind;

  const PendingAttachment({
    required this.name,
    required this.path,
    required this.kind,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AiService _aiService = AiService();
  final NotificationService _notificationService = NotificationService();

  final List<ChatMessage> _messages = [];
  final List<PendingAttachment> _pendingAttachments = [];
  final List<String> _quickPrompts = const [
    'Explain this simply',
    'Summarize it for me',
    'Draft a quick reply',
    'Give me the short answer',
    'What should I do next?',
  ];
  bool _isLoading = false;
  bool _companionMode = true;
  String _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
  String _sessionTitle = 'New chat';

  @override
  void initState() {
    super.initState();
    unawaited(_aiService.init());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _showStatus(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  Future<void> _saveSession() async {
    if (_messages.isEmpty) return;
    if (_sessionTitle.isEmpty || _sessionTitle == 'New chat') {
      final firstUser = _messages.firstWhere(
        (m) => m.isUser,
        orElse: () => ChatMessage(role: 'user', content: 'New chat'),
      );
      _sessionTitle =
          firstUser.content.length > 28 ? '${firstUser.content.substring(0, 25)}...' : firstUser.content;
    }
    final session = ChatSession(
      id: _sessionId,
      title: _sessionTitle,
      timestamp: DateTime.now(),
      messages: _messages.map((m) => m.toJson()).toList(),
    );
    await ChatHistoryService.saveSession(session);
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    setState(() {
      _pendingAttachments.add(
        PendingAttachment(
          name: file.name,
          path: file.path,
          kind: 'photo',
        ),
      );
    });
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
      type: FileType.any,
    );
    if (result == null || result.files.isEmpty) return;
    setState(() {
      for (final file in result.files) {
        final filePath = file.path ?? file.name;
        if (filePath.isEmpty) continue;
        _pendingAttachments.add(
          PendingAttachment(
            name: file.name,
            path: filePath,
            kind: file.extension?.isNotEmpty == true ? file.extension! : 'file',
          ),
        );
      }
    });
  }

  void _removeAttachment(int index) {
    setState(() {
      _pendingAttachments.removeAt(index);
    });
  }

  String _formatAttachmentContext() {
    if (_pendingAttachments.isEmpty) return '';
    final items = _pendingAttachments.map((a) => '${a.kind}:${a.name}').join('; ');
    return 'User attached: $items';
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _applyQuickPrompt(String prompt) {
    setState(() {
      _textController.text = prompt;
      _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: _textController.text.length),
      );
    });
  }

  Future<void> _sendMessage(String text) async {
    final trimmed = text.trim();
    final hasAttachmentContext = _pendingAttachments.isNotEmpty;
    if (trimmed.isEmpty && !hasAttachmentContext) return;

    final userMessageText = trimmed.isEmpty
        ? 'Shared ${_pendingAttachments.length} attachment${_pendingAttachments.length == 1 ? '' : 's'}.'
        : trimmed;

    final promptText = hasAttachmentContext
        ? '$userMessageText\n\n${_formatAttachmentContext()}\n\nPlease answer naturally and helpfully using the attachment context.'
        : userMessageText;

    final userMessage = ChatMessage(role: 'user', content: promptText);
    setState(() {
      _messages.add(userMessage);
      _isLoading = true;
    });
    _textController.clear();
    _pendingAttachments.clear();
    _scrollToBottom();
    await _saveSession();

    final assistantMessage = ChatMessage(role: 'assistant', content: '');
    setState(() {
      _messages.add(assistantMessage);
    });
    final assistantIndex = _messages.length - 1;

    try {
      var accumulated = '';
      await for (final chunk in _aiService.sendMessageStream(promptText, isAgentMode: false)) {
        accumulated += chunk;
        if (!mounted) return;
        setState(() {
          _messages[assistantIndex] = ChatMessage(
            role: 'assistant',
            content: accumulated,
            timestamp: assistantMessage.timestamp,
          );
        });
        _scrollToBottom();
      }

      if (!mounted) return;
      setState(() {
        _messages[assistantIndex] = ChatMessage(
          role: 'assistant',
          content: accumulated.trim(),
          timestamp: assistantMessage.timestamp,
        );
      });
      _scrollToBottom();
      await _saveSession();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (_messages.length > assistantIndex) {
          _messages.removeAt(assistantIndex);
        }
        _messages.add(
          ChatMessage(
            role: 'assistant',
            content: 'Hmm, something went wrong. Try again—${e.toString().replaceFirst('Exception: ', '')}',
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Widget _buildAttachmentRow() {
    if (_pendingAttachments.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(0, 0, 0, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (int i = 0; i < _pendingAttachments.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.attach_file_rounded, size: 14, color: Colors.white70),
                  const SizedBox(width: 6),
                  Text(
                    _pendingAttachments[i].name,
                    style: const TextStyle(fontSize: 11, color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () => _removeAttachment(i),
                    child: const Icon(Icons.close_rounded, size: 14, color: Colors.white54),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildQuickActions() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _quickPrompts
            .map(
              (prompt) => ActionChip(
                backgroundColor: const Color(0xFF111827),
                label: Text(prompt, style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                avatar: const Icon(Icons.auto_awesome_rounded, size: 14, color: Color(0xFF8B5CF6)),
                onPressed: () => _applyQuickPrompt(prompt),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildInputBar() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF334155)),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(0, 6)),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildAttachmentRow(),
                Row(
                  children: [
                    IconButton(
                      onPressed: _isLoading ? null : _pickImage,
                      icon: const Icon(Icons.photo_library_rounded, color: Colors.white70),
                      tooltip: 'Add photo',
                    ),
                    IconButton(
                      onPressed: _isLoading ? null : _pickFiles,
                      icon: const Icon(Icons.attach_file_rounded, color: Colors.white70),
                      tooltip: 'Add file',
                    ),
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: _isLoading ? null : (value) => _sendMessage(value),
                        style: const TextStyle(color: Colors.white, fontSize: 15),
                        decoration: const InputDecoration(
                          hintText: 'Ask me anything...',
                          hintStyle: TextStyle(color: Colors.white54),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _isLoading ? null : () => _sendMessage(_textController.text),
                      icon: const Icon(Icons.send_rounded, color: Color(0xFF8B5CF6)),
                      tooltip: 'Send',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF04070B),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF8B5CF6).withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.smart_toy_rounded, color: Color(0xFF8B5CF6), size: 18),
            ),
            const SizedBox(width: 10),
            const Text('Private Assistant', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () {
              setState(() {
                _companionMode = !_companionMode;
              });
            },
            icon: Icon(_companionMode ? Icons.favorite_rounded : Icons.favorite_border_rounded),
            tooltip: 'Friend mode',
          ),
          IconButton(
            onPressed: () async {
              final session = ChatSession(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                title: 'New chat',
                timestamp: DateTime.now(),
                messages: const [],
              );
              await ChatHistoryService.saveSession(session);
              setState(() {
                _messages.clear();
                _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
                _sessionTitle = 'New chat';
              });
            },
            icon: const Icon(Icons.add_comment_rounded),
            tooltip: 'New chat',
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF101827),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF1F2937)),
            ),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isLoading ? Colors.orangeAccent : Colors.greenAccent,
                    boxShadow: [
                      BoxShadow(
                        color: (_isLoading ? Colors.orangeAccent : Colors.greenAccent).withOpacity(0.7),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _isLoading ? 'Thinking and helping...' : (_companionMode ? 'Friend mode is on and ready' : 'Jarvis mode is on'),
                    style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                  ),
                ),
                Text(
                  _companionMode ? 'FRIEND MODE' : 'JARVIS MODE',
                  style: const TextStyle(
                    color: Color(0xFF8B5CF6),
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          _buildQuickActions(),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.chat_bubble_outline_rounded, size: 54, color: Colors.white30),
                          const SizedBox(height: 18),
                          const Text(
                            'Hey, what can I help with?',
                            style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Ask a question, send a photo, share a file, or just talk naturally.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final streaming = _isLoading && index == _messages.length - 1;
                      return RepaintBoundary(
                        child: MessageBubble(
                          message: _messages[index],
                          streaming: streaming,
                        ),
                      );
                    },
                  ),
          ),
          _buildInputBar(),
        ],
      ),
    );
  }
}
