import 'dart:convert';

import 'package:astra_gui/data/models/models.dart';
import 'package:astra_gui/data/providers/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ProviderAccount _account(
  ProviderFormat format, {
  String baseUrl = 'https://example.test/v1',
}) =>
    ProviderAccount(
      id: 'account-1',
      name: 'Test',
      format: format,
      baseUrl: format == ProviderFormat.anthropic
          ? 'https://api.anthropic.test'
          : baseUrl,
      defaultModelId: 'test-model',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      hlc: '1:0:test',
    );

ModelInfo _model() => ModelInfo(
      id: 'model-row',
      accountId: 'account-1',
      modelId: 'test-model',
      displayName: 'Test Model',
      enabled: true,
      supportsVision: true,
      supportsTools: true,
      supportsReasoning: true,
      source: 'manual',
      updatedAt: '2026-01-01T00:00:00Z',
      hlc: '1:0:test',
    );

AppSettings _settings() => AppSettings.defaults(
      deviceId: 'device-1',
      deviceName: 'Test Device',
    )
      ..maxTokens = 256
      ..temperature = 0.2;

Turn _userTurn() => Turn.user(
      conversationId: 'chat-1',
      blocks: [ContentBlock.text('hello')],
      hlc: '2:0:test',
    );

const _tool = ToolDefinition(
  name: 'web_search',
  description: 'Search the web',
  inputSchema: {
    'type': 'object',
    'properties': {
      'query': {'type': 'string'},
    },
    'required': ['query'],
  },
  requiresApproval: false,
);

void main() {
  test('fetch OpenAI models', () async {
    final client = LlmClient(
      clientFactory: () => MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.toString(), 'https://example.test/v1/models');
        expect(
          request.headers.entries
              .firstWhere((entry) => entry.key.toLowerCase() == 'authorization')
              .value,
          'Bearer sk-test',
        );
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'gpt-4o-mini'},
              {'id': 'gpt-4.1'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final models = await client.fetchModels(
      account: _account(ProviderFormat.openai),
      apiKey: 'sk-test',
    );
    expect(models.map((item) => item.id), ['gpt-4.1', 'gpt-4o-mini']);
  });

  test('fetch Anthropic models', () async {
    final client = LlmClient(
      clientFactory: () => MockClient((request) async {
        expect(request.url.toString(), 'https://api.anthropic.test/v1/models?limit=1000');
        expect(
          request.headers.entries
              .firstWhere((entry) => entry.key.toLowerCase() == 'x-api-key')
              .value,
          'sk-ant',
        );
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'claude-opus-5', 'display_name': 'Claude Opus 5'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final models = await client.fetchModels(
      account: _account(ProviderFormat.anthropic),
      apiKey: 'sk-ant',
    );
    expect(models.single.displayName, 'Claude Opus 5');
  });

  test('OpenAI SSE with text, reasoning and tool call', () async {
    late Map<String, dynamic> sent;
    final body = [
      'data: {"choices":[{"delta":{"reasoning_content":"plan"}}]}',
      '',
      'data: {"choices":[{"delta":{"content":"hello "}}]}',
      '',
      'data: {"choices":[{"delta":{"content":"world"}}]}',
      '',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1",'
          '"function":{"name":"web_search","arguments":"{\\"query\\":\\"astra\\"}"}}]}}]}',
      '',
      'data: [DONE]',
      '',
    ].join('\n');

    final client = LlmClient(
      clientFactory: () => MockClient((request) async {
        expect(request.url.toString(), 'https://example.test/v1/chat/completions');
        sent = asMapForTest(jsonDecode(request.body));
        return http.Response(
          body,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final result = await client.streamChat(
      account: _account(ProviderFormat.openai),
      model: _model(),
      apiKey: 'sk-test',
      turns: [_userTurn()],
      images: const {},
      systemPrompt: '',
      settings: _settings(),
      tools: const [_tool],
      cancelToken: CancelToken(),
      callbacks: StreamCallbacks(
        onText: text.write,
        onReasoning: reasoning.write,
      ),
    );

    expect(text.toString(), 'hello world');
    expect(reasoning.toString(), 'plan');
    expect(result.toolCalls.single.name, 'web_search');
    expect(result.toolCalls.single.arguments()['query'], 'astra');
    expect(sent['model'], 'test-model');
    expect(sent.containsKey('system'), isFalse);
    expect(sent['temperature'], 0.2);
    expect(sent['stream'], isTrue);
    expect(sent['tools'], isA<List<dynamic>>());
  });

  test('Anthropic SSE preserving thinking and tool use', () async {
    late Map<String, dynamic> sent;
    final events = [
      {
        'type': 'message_start',
        'message': {
          'id': 'msg_1',
          'type': 'message',
          'role': 'assistant',
          'model': 'test-model',
          'content': [],
          'stop_reason': null,
          'stop_sequence': null,
          'usage': {'input_tokens': 10, 'output_tokens': 1},
        },
      },
      {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {
          'type': 'thinking',
          'thinking': '',
          'signature': '',
        },
      },
      {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'thinking_delta', 'thinking': 'pondering'},
      },
      {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'signature_delta', 'signature': 'sig-1'},
      },
      {'type': 'content_block_stop', 'index': 0},
      {
        'type': 'content_block_start',
        'index': 1,
        'content_block': {
          'type': 'tool_use',
          'id': 'toolu_1',
          'name': 'run_python',
          'input': {},
        },
      },
      {
        'type': 'content_block_delta',
        'index': 1,
        'delta': {
          'type': 'input_json_delta',
          'partial_json': '{"code":"print(1)"}',
        },
      },
      {'type': 'content_block_stop', 'index': 1},
      {
        'type': 'content_block_start',
        'index': 2,
        'content_block': {'type': 'text', 'text': ''},
      },
      {
        'type': 'content_block_delta',
        'index': 2,
        'delta': {'type': 'text_delta', 'text': 'done'},
      },
      {'type': 'content_block_stop', 'index': 2},
      {
        'type': 'message_delta',
        'delta': {'stop_reason': 'tool_use', 'stop_sequence': null},
        'usage': {'output_tokens': 20},
      },
      {'type': 'message_stop'},
    ];
    final body = events
        .map((event) => 'event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n')
        .join();

    final client = LlmClient(
      clientFactory: () => MockClient((request) async {
        expect(request.url.toString(), 'https://api.anthropic.test/v1/messages');
        sent = asMapForTest(jsonDecode(request.body));
        return http.Response(
          body,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final result = await client.streamChat(
      account: _account(ProviderFormat.anthropic),
      model: _model(),
      apiKey: 'sk-ant',
      turns: [_userTurn()],
      images: const {},
      systemPrompt: '',
      settings: _settings(),
      tools: const [_tool],
      cancelToken: CancelToken(),
      callbacks: StreamCallbacks(
        onText: text.write,
        onReasoning: reasoning.write,
      ),
    );

    expect(text.toString(), 'done');
    expect(reasoning.toString(), 'pondering');
    expect(result.stopReason, 'tool_use');
    expect(result.toolCalls.single.name, 'run_python');
    expect(result.toolCalls.single.arguments()['code'], 'print(1)');
    final thinking = result.providerRaw
        .firstWhere((block) => block['type'] == 'thinking');
    expect(thinking['signature'], 'sig-1');
    expect(sent['thinking'], {'type': 'adaptive', 'display': 'summarized'});
    expect(sent.containsKey('temperature'), isFalse);
    expect(sent.containsKey('system'), isFalse);
    expect(sent['tools'], isA<List<dynamic>>());
  });
}

Map<String, dynamic> asMapForTest(dynamic value) =>
    value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};
