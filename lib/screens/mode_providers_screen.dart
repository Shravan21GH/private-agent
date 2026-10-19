import 'package:flutter/material.dart';
import '../config/zax_mode.dart';
import '../services/ai_service.dart';

/// Lets each Zax mode (Normal, Study, Code) have its own AI provider, key and
/// model. Changing one mode never changes another. A mode with nothing saved
/// here simply uses the main provider from Settings.
class ModeProvidersScreen extends StatelessWidget {
  final AiService aiService;

  const ModeProvidersScreen({super.key, required this.aiService});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mode Providers')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Each mode can use its own AI provider. A mode with nothing saved '
            'here uses the main provider from Settings. If a provider fails '
            '(for example a free limit is reached), Zax shows the real error '
            'and never switches to another provider by itself.',
          ),
          const SizedBox(height: 16),
          _ModeProviderCard(
            aiService: aiService,
            mode: ZaxMode.normal,
            presetLabel: 'Groq',
            presetBaseUrl: 'https://api.groq.com/openai/v1',
            presetModel: '',
            help: 'Everyday chat. Leave empty to keep using the main provider.',
          ),
          _ModeProviderCard(
            aiService: aiService,
            mode: ZaxMode.study,
            presetLabel: 'Gemini',
            presetBaseUrl:
                'https://generativelanguage.googleapis.com/v1beta/openai',
            presetModel: '',
            help: 'School explanations. Paste your Gemini key, then tap '
                '"Fetch models" and pick one.',
          ),
          _ModeProviderCard(
            aiService: aiService,
            mode: ZaxMode.programming,
            presetLabel: 'OpenRouter free',
            presetBaseUrl: 'https://openrouter.ai/api/v1',
            presetModel: 'cohere/north-mini-code:free',
            help: 'Roblox / Luau coding. Paste your OpenRouter key. Keep the '
                'model ending in ":free" so you are never charged.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Image mode uses Pollinations and has no key here. Phone-control '
            '(Agent) tasks always use the main provider.',
          ),
        ],
      ),
    );
  }
}

class _ModeProviderCard extends StatefulWidget {
  final AiService aiService;
  final ZaxMode mode;
  final String presetLabel;
  final String presetBaseUrl;
  final String presetModel;
  final String help;

  const _ModeProviderCard({
    required this.aiService,
    required this.mode,
    required this.presetLabel,
    required this.presetBaseUrl,
    required this.presetModel,
    required this.help,
  });

  @override
  State<_ModeProviderCard> createState() => _ModeProviderCardState();
}

class _ModeProviderCardState extends State<_ModeProviderCard> {
  late final TextEditingController _keyController;
  late final TextEditingController _urlController;
  late final TextEditingController _modelController;
  bool _hideKey = true;
  bool _busy = false;
  String? _status;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    final saved = widget.aiService.modeProviderFor(widget.mode.name);
    _keyController = TextEditingController(text: saved?.apiKey ?? '');
    _urlController = TextEditingController(text: saved?.baseUrl ?? '');
    _modelController = TextEditingController(text: saved?.model ?? '');
  }

  @override
  void dispose() {
    _keyController.dispose();
    _urlController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  String _cleanUrl(String url) => url.trim().replaceAll(RegExp(r'/+$'), '');

  void _setStatus(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _statusIsError = error;
    });
  }

  void _applyPreset() {
    setState(() {
      _urlController.text = widget.presetBaseUrl;
      if (widget.presetModel.isNotEmpty) {
        _modelController.text = widget.presetModel;
      }
      _status = null;
    });
  }

  Future<void> _fetchModels() async {
    final url = _cleanUrl(_urlController.text);
    final key = _keyController.text.trim();
    if (url.isEmpty || key.isEmpty) {
      _setStatus('Enter the API key and Base URL first.', error: true);
      return;
    }
    setState(() => _busy = true);
    final models = await widget.aiService.fetchAvailableModels(url, key);
    if (!mounted) return;
    setState(() => _busy = false);
    if (models.isEmpty) {
      _setStatus(
        'Could not load the model list. Check the key and the Base URL.',
        error: true,
      );
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select a model'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: models.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(models[i]),
              onTap: () => Navigator.pop(ctx, models[i]),
            ),
          ),
        ),
      ),
    );
    if (picked != null) {
      setState(() {
        // Gemini lists names like "models/gemini-..."; chat wants the short name.
        _modelController.text =
            picked.startsWith('models/') ? picked.substring(7) : picked;
        _status = null;
      });
    }
  }

  Future<void> _save() async {
    final key = _keyController.text.trim();
    final url = _cleanUrl(_urlController.text);
    final model = _modelController.text.trim();
    if (key.isEmpty || url.isEmpty || model.isEmpty) {
      _setStatus(
        'Fill in the API key, Base URL and Model, or tap "Use main provider".',
        error: true,
      );
      return;
    }
    await widget.aiService.saveModeProvider(
      widget.mode.name,
      apiKey: key,
      baseUrl: url,
      model: model,
    );
    _setStatus('Saved. This mode will now use $model. (Not tested yet.)');
  }

  Future<void> _useMain() async {
    await widget.aiService.clearModeProvider(widget.mode.name);
    if (!mounted) return;
    setState(() {
      _keyController.clear();
      _urlController.clear();
      _modelController.clear();
    });
    _setStatus('This mode now uses the main provider.');
  }

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(widget.mode.icon, color: widget.mode.color),
                const SizedBox(width: 8),
                Text(
                  '${widget.mode.label} mode',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(widget.help, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: _keyController,
              obscureText: _hideKey,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'API key',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_hideKey ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _hideKey = !_hideKey),
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _urlController,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  label: Text(widget.presetLabel),
                  onPressed: _applyPreset,
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _modelController,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Model',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : _fetchModels,
                  child: Text(_busy ? 'Loading...' : 'Fetch models'),
                ),
                FilledButton(onPressed: _save, child: const Text('Save')),
                TextButton(
                  onPressed: _useMain,
                  child: const Text('Use main provider'),
                ),
              ],
            ),
            if (_status != null) ...[
              const SizedBox(height: 10),
              Text(
                _status!,
                style: TextStyle(
                  fontSize: 12,
                  color: _statusIsError ? errorColor : null,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
