import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_service.dart';

/// Lets Zax "see" a photo. The picture is sent to the first provider that can
/// look at images: your Normal-mode providers first (Groq and Gemini both
/// can), then the main provider.
class VisionService {
  VisionService._();

  static const String groqVisionModel =
      'meta-llama/llama-4-scout-17b-16e-instruct';

  static String _chatUrl(String baseUrl) {
    var url = baseUrl.trim();
    if (url.endsWith('/chat/completions')) return url;
    if (url.endsWith('/')) return '${url}chat/completions';
    return '$url/chat/completions';
  }

  /// Returns Zax's description/answer, or throws an Exception with a clear
  /// reason when no provider could look at the picture.
  static Future<String> describe({
    required AiService ai,
    required File image,
    required String question,
  }) async {
    final bytes = await image.readAsBytes();
    if (bytes.length > 4 * 1024 * 1024) {
      throw Exception('That photo is too big to send (over 4 MB).');
    }
    final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';

    final prefs = await SharedPreferences.getInstance();
    final customVisionModel = prefs.getString('vision_model') ?? '';

    // Candidate providers: Normal-mode slots 1-4, then the main provider.
    final candidates = <ModeProvider>[];
    for (int slot = 1; slot <= AiService.providerSlots; slot++) {
      final p = ai.modeProviderFor(AiService.slotKey('normal', slot));
      if (p != null && p.isConfigured) candidates.add(p);
    }
    if (ai.isConfigured) {
      candidates.add(
        ModeProvider(apiKey: ai.apiKey, baseUrl: ai.baseUrl, model: ai.model),
      );
    }
    if (candidates.isEmpty) {
      throw Exception(
        'No AI provider is set up yet. Add one in Settings or Mode Providers.',
      );
    }

    final errors = <String>[];
    for (final p in candidates) {
      final host = p.baseUrl.toLowerCase();
      String model = p.model;
      if (customVisionModel.isNotEmpty) {
        model = customVisionModel;
      } else if (host.contains('groq.com')) {
        model = groqVisionModel;
      }
      try {
        final response = await http
            .post(
              Uri.parse(_chatUrl(p.baseUrl)),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${p.apiKey}',
              },
              body: jsonEncode({
                'model': model,
                'max_tokens': 700,
                'messages': [
                  {
                    'role': 'user',
                    'content': [
                      {
                        'type': 'text',
                        'text':
                            'You are Zax, a friendly personal assistant. The '
                            'user took this photo with their phone camera and '
                            'said: "$question". Answer helpfully, briefly and '
                            'in a natural, friendly way. If you cannot tell, '
                            'say so honestly.',
                      },
                      {
                        'type': 'image_url',
                        'image_url': {'url': dataUrl},
                      },
                    ],
                  },
                ],
              }),
            )
            .timeout(const Duration(seconds: 60));

        if (response.statusCode != 200) {
          var message = response.body;
          try {
            final decoded = jsonDecode(response.body);
            if (decoded is Map && decoded['error'] is Map) {
              message = '${(decoded['error'] as Map)['message']}';
            }
          } catch (_) {}
          errors.add('$model: $message');
          continue;
        }

        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map && decoded['choices'] is List) {
          final choices = decoded['choices'] as List;
          if (choices.isNotEmpty && choices.first is Map) {
            final msg = (choices.first as Map)['message'];
            if (msg is Map && msg['content'] is String) {
              final text = (msg['content'] as String).trim();
              if (text.isNotEmpty) return text;
            }
          }
        }
        errors.add('$model: empty answer');
      } catch (e) {
        errors.add('$model: $e');
      }
    }

    throw Exception(
      'None of your providers could look at the photo. For a free option, '
      'add Groq or Gemini under Mode Providers (Normal mode). Details: '
      '${errors.join(' | ')}',
    );
  }
}
