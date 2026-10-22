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
            'Each mode can have up to 4 AI providers. Zax tries Provider 1 '
            'first. If it fails (for example a free limit is reached), Zax '
            'automatically tries Provider 2, then 3, then 4, and tells you '
            'which one answered. A mode with nothing saved uses the main '
            'provider from Settings. Use free providers and free models only.',
          ),
          const SizedBox(height: 16),
          for (final spec in _specs) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Row(
                children: [
                  Icon(spec.mode.icon, color: spec.mode.color),
                  const SizedBox(width: 8),
                  Text(
                    '${spec.mode.label} mode',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(spec.help, style: const TextStyle(fontSize: 12)),
            ),
            for (int slot = 1; slot <= AiService.providerSlots; slot++)
              _ModeProviderCard(
                key: ValueKey('${spec.mode.name}_$slot'),
                aiService: aiService,
                mode: spec.mode,
                slot: slot,
                presetLabel: spec.presetLabel,
                presetBaseUrl: spec.presetBaseUrl,
                presetModel: spec.presetModel,
              ),
          ],
          const SizedBox(height: 8),
          const Text(
            'Image mode uses Pollinations and has no key here. Phone-control '
            '(Agent) tasks always use the main provider. Photos you take with '
            'the camera go to your Normal-mode providers (Groq and Gemini can '
            'look at pictures).',
          ),
        ],
      ),
    );
  }
}

class _ModeSpec {
  final ZaxMode mode;
  final String presetLabel;
  final String presetBaseUrl;
  final String presetModel;
  final String help;

  const _ModeSpec(
    this.mode,
    this.presetLabel,
    this.presetBaseUrl,
    this.presetModel,
    this.help,
  );
}

const List<_ModeSpec> _specs = [
  _ModeSpec(
    ZaxMode.normal,
    'Groq',
    'https://api.groq.com/openai/v1',
    '',
    'Everyday chat. Suggested: Provider 1 = Groq.',
  ),
  _ModeSpec(
    ZaxMode.study,
    'Gemini',
    'https://generativelanguage.googleapis.com/v1beta/openai',
    '',
    'School explanations. Suggested: Provider 1 = Gemini. Paste your key, '
        'then tap "Fetch models" and pick one.',
  ),
  _ModeSpec(
    ZaxMode.programming,
    'OpenRouter free',
    'https://openrouter.ai/api/v1',
    'cohere/north-mini-code:free',
    'Roblox / Luau coding. Suggested: Provider 1 = OpenRouter. Keep a model '
        'ending in ":free" so you are never charged.',
  ),
];

/// Quick-fill buttons: the mode's own suggestion first, then other common
/// OpenAI-compatible providers that have a free tier.
List<(String, String, String)> _presets(String label, String url, String model) {
  final list = <(String, String, String)>[(label, url, model)];
  const others = <(String, String)>[
    ('Groq', 'https://api.groq.com/openai/v1'),
    ('Gemini', 'https://generativelanguage.googleapis.com/v1beta/openai'),
    ('OpenRouter', 'https://openrouter.ai/api/v1'),
    ('Cerebras', 'https://api.cerebras.ai/v1'),
    ('NVIDIA', 'https://integrate.api.nvidia.com/v1'),
  ];
  for (final o in others) {
    if (o.$2 != url) list.add((o.$1, o.$2, ''));
  }
  return list;
}

class _ModeProviderCard extends StatefulWidget {
  final AiService aiService;
  final ZaxMode mode;
  final String presetLabel;
  final String presetBaseUrl;
  final String presetModel;
  final int slot;

  const _ModeProviderCard({
    super.key,
    required this.aiService,
    required this.mode,
    required this.slot,
    required this.presetLabel,
    required this.presetBaseUrl,
    required this.presetModel,
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
    final saved = widget.aiService.modeProviderFor(_slotId);
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

  String get _slotId => AiService.slotKey(widget.mode.name, widget.slot);

  String _cleanUrl(String url) => url.trim().replaceAll(RegExp(r'/+$'), '');

  void _setStatus(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _statusIsError = error;
    });
  }

  void _applyPreset(String url, String model) {
    setState(() {
      _urlController.text = url;
      if (model.isNotEmpty) {
        _modelController.text = model;
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
      _slotId,
      apiKey: key,
      baseUrl: url,
      model: model,
    );
    _setStatus(
      'Saved as Provider ${widget.slot}. Zax will use $model for '
      '${widget.mode.label} mode. (Not tested yet.)',
    );
  }

  Future<void> _useMain() async {
    await widget.aiService.clearModeProvider(_slotId);
    if (!mounted) return;
    setState(() {
      _keyController.clear();
      _urlController.clear();
      _modelController.clear();
    });
    _setStatus('Provider ${widget.slot} is now empty.');
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
            Text(
              widget.slot == 1
                  ? 'Provider 1 (tried first)'
                  : 'Provider ${widget.slot} (backup ${widget.slot - 1})',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
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
                for (final p in _presets(
                  widget.presetLabel,
                  widget.presetBaseUrl,
                  widget.presetModel,
                ))
                  ActionChip(
                    label: Text(p.$1),
                    onPressed: () => _applyPreset(p.$2, p.$3),
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
                  child: const Text('Clear this provider'),
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
