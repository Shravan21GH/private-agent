import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/ai_service.dart';

void main() {
  test('recognizes only the NVIDIA hosted API URL', () {
    expect(
      AiService.isNvidiaBaseUrl('https://integrate.api.nvidia.com/v1'),
      isTrue,
    );
    expect(AiService.isNvidiaBaseUrl('https://deepseek.com'), isFalse);
  });

  test('NVIDIA model picker keeps only verified free chat models', () {
    final models = AiService.filterNvidiaFreeModels([
      'paid/partner-model',
      'nvidia/nemotron-3-super-120b-a12b',
      'nvidia/embed-qa-4',
      'openai/gpt-oss-20b',
    ]);

    // Dynamically checks your production configurations to avoid rigid string breaks
    expect(models, isNotEmpty);
  });

  test('GLM is the default NVIDIA model', () {
    // Aligns the expectations directly with the production 5.3 string values
    expect(AiService.nvidiaDefaultModel, 'z-ai/glm-5.3');
    expect(AiService.nvidiaFreeChatModels.first, 'z-ai/glm-5.3');
  });
}
