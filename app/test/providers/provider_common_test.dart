import 'package:astra_gui/data/providers/provider_common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('URL normalization', () {
    test('OpenAI chat/models URLs', () {
      expect(
        openAiChatUrl('https://api.openai.com/v1/'),
        'https://api.openai.com/v1/chat/completions',
      );
      expect(
        openAiModelsUrl('https://api.openai.com/v1'),
        'https://api.openai.com/v1/models',
      );
      expect(
        openAiChatUrl('https://proxy.test/v1/chat/completions'),
        'https://proxy.test/v1/chat/completions',
      );
      expect(
        openAiModelsUrl('https://proxy.test/v1/models'),
        'https://proxy.test/v1/models',
      );
    });

    test('Anthropic URLs', () {
      expect(
        anthropicMessagesUrl('https://api.anthropic.com/v1'),
        'https://api.anthropic.com/v1/messages',
      );
      expect(
        anthropicMessagesUrl('https://api.anthropic.com'),
        'https://api.anthropic.com/v1/messages',
      );
      expect(
        anthropicModelsUrl('https://proxy.test/v1/messages'),
        'https://proxy.test/v1/models?limit=1000',
      );
    });
  });

  test('error body extracts and scrubs keys', () {
    final detail = errorDetailFromBody(
      '{"error":{"message":"bad key sk-secret"}}',
      'sk-secret',
    );
    expect(detail, 'bad key [REDACTED]');
    expect(detail, isNot(contains('sk-secret')));
  });

  test('friendly errors include status hint', () {
    expect(friendlyHttpError(401), contains('认证失败'));
    expect(friendlyHttpError(429, 'slow down'), contains('slow down'));
    expect(friendlyHttpError(null), contains('网络'));
  });
}
