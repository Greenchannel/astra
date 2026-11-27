import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../util/json.dart';
import '../models/models.dart';
import 'provider_common.dart';

class LlmClient {
  LlmClient({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;

  // ----------------------------------------------------------------- models
  Future<List<RemoteModel>> fetchModels({
    required ProviderAccount account,
    required String apiKey,
    CancelToken? cancelToken,
  }) async {
    if (account.format == ProviderFormat.anthropic) {
      final uri = Uri.parse(anthropicModelsUrl(account.baseUrl));
      final client = _clientFactory();
      _bindCancel(cancelToken, client);
      try {
        final response = await client.get(
          uri,
          headers: {
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
          },
        ).timeout(const Duration(seconds: 30));
        if (response.statusCode >= 400) {
          final detail = errorDetailFromBody(
            utf8.decode(response.bodyBytes, allowMalformed: true),
            apiKey,
          );
          throw ProviderException(
            response.statusCode,
            friendlyHttpError(response.statusCode, detail),
          );
        }
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final data = decoded is Map ? decoded['data'] : null;
        final result = <RemoteModel>[];
        if (data is List) {
          for (final item in data) {
            if (item is! Map) continue;
            final id = item['id'];
            if (id is! String || id.isEmpty) continue;
            final name = item['display_name'];
            result.add(
              RemoteModel(
                id: id,
                displayName: name is String && name.isNotEmpty ? name : id,
              ),
            );
          }
        }
        result.sort((a, b) => a.id.compareTo(b.id));
        return result;
      } on ProviderException {
        rethrow;
      } on CancelledException {
        rethrow;
      } catch (error) {
        if (cancelToken?.isCancelled == true) throw CancelledException();
        throw ProviderException(
          null,
          friendlyHttpError(null, scrubSecret('$error', apiKey)),
        );
      } finally {
        client.close();
      }
    }

    final uri = Uri.parse(openAiModelsUrl(account.baseUrl));
    final client = _clientFactory();
    _bindCancel(cancelToken, client);
    try {
      final response = await client.get(
        uri,
        headers: {'Authorization': 'Bearer $apiKey'},
      ).timeout(const Duration(seconds: 30));
      if (response.statusCode >= 400) {
        final detail = errorDetailFromBody(
          utf8.decode(response.bodyBytes, allowMalformed: true),
          apiKey,
        );
        throw ProviderException(
          response.statusCode,
          friendlyHttpError(response.statusCode, detail),
        );
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final data = decoded is Map ? decoded['data'] : null;
      final result = <RemoteModel>[];
      if (data is List) {
        for (final item in data) {
          if (item is! Map) continue;
          final id = item['id'];
          if (id is String && id.isNotEmpty) {
            final name = item['name'];
            result.add(
              RemoteModel(
                id: id,
                displayName: name is String && name.isNotEmpty ? name : id,
              ),
            );
          }
        }
      }
      result.sort((a, b) => a.id.compareTo(b.id));
      return result;
    } on ProviderException {
      rethrow;
    } on CancelledException {
      rethrow;
    } catch (error) {
      if (cancelToken?.isCancelled == true) throw CancelledException();
      throw ProviderException(
        null,
        friendlyHttpError(null, scrubSecret('$error', apiKey)),
      );
    } finally {
      client.close();
    }
  }

  // --------------------------------------------------------------- streaming
  Future<ProviderResult> streamChat({
    required ProviderAccount account,
    required ModelInfo model,
    required String apiKey,
    required List<Turn> turns,
    required Map<String, ImagePayload> images,
    required String systemPrompt,
    required AppSettings settings,
    required List<ToolDefinition> tools,
    required StreamCallbacks callbacks,
    required CancelToken cancelToken,
  }) async {
    final recentImages = _recentImageIds(turns);
    if (account.format == ProviderFormat.anthropic) {
      return _streamAnthropic(
        account: account,
        model: model,
        apiKey: apiKey,
        turns: turns,
        images: images,
        recentImageIds: recentImages,
        systemPrompt: systemPrompt,
        settings: settings,
        tools: tools,
        callbacks: callbacks,
        cancelToken: cancelToken,
      );
    }
    return _streamOpenAi(
      account: account,
      model: model,
      apiKey: apiKey,
      turns: turns,
      images: images,
      recentImageIds: recentImages,
      systemPrompt: systemPrompt,
      settings: settings,
      tools: tools,
      callbacks: callbacks,
      cancelToken: cancelToken,
    );
  }

  Future<ProviderResult> _streamOpenAi({
    required ProviderAccount account,
    required ModelInfo model,
    required String apiKey,
    required List<Turn> turns,
    required Map<String, ImagePayload> images,
    required Set<String> recentImageIds,
    required String systemPrompt,
    required AppSettings settings,
    required List<ToolDefinition> tools,
    required StreamCallbacks callbacks,
    required CancelToken cancelToken,
  }) async {
    final messages = _openAiMessages(
      turns: turns,
      images: images,
      recentImageIds: recentImageIds,
    );
    if (systemPrompt.trim().isNotEmpty) {
      messages.insert(0, {'role': 'system', 'content': systemPrompt});
    }
    final payload = <String, dynamic>{
      'model': model.modelId,
      'messages': messages,
      'stream': true,
    };
    if (settings.maxTokens > 0) payload['max_tokens'] = settings.maxTokens;
    if (settings.temperature != null) {
      payload['temperature'] = settings.temperature;
    }
    if (tools.isNotEmpty && model.supportsTools) {
      payload['tools'] = tools.map((tool) => tool.toOpenAi()).toList();
      payload['tool_choice'] = 'auto';
    }

    final client = _clientFactory();
    _bindCancel(cancelToken, client);
    try {
      final request = http.Request(
        'POST',
        Uri.parse(openAiChatUrl(account.baseUrl)),
      )
        ..headers.addAll({
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream',
        })
        ..body = jsonEncode(payload);
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode >= 400) {
        final body = await response.stream.bytesToString();
        throw ProviderException(
          response.statusCode,
          friendlyHttpError(
            response.statusCode,
            errorDetailFromBody(body, apiKey),
          ),
        );
      }

      final contentType = response.headers['content-type'] ?? '';
      if (!contentType.toLowerCase().contains('text/event-stream')) {
        final body = await response.stream.bytesToString();
        return _parseOpenAiCompletion(body, apiKey, callbacks);
      }

      final textBuffer = StringBuffer();
      final reasoningBuffer = StringBuffer();
      final toolAcc = <int, _OpenAiToolAcc>{};
      Map<String, dynamic>? usage;
      var sawDone = false;

      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(const Duration(seconds: 120))) {
        if (cancelToken.isCancelled) throw CancelledException();
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith(':')) continue;
        if (!trimmed.startsWith('data:')) continue;
        final data = trimmed.substring(5).trim();
        if (data == '[DONE]') {
          sawDone = true;
          break;
        }
        final decoded = _tryJson(data);
        if (decoded is! Map) continue;
        final error = decoded['error'];
        if (error != null) {
          final message = error is Map
              ? error['message'] ?? error['detail'] ?? error['type']
              : error;
          throw ProviderException(
            null,
            scrubSecret(message is String ? message : '$message', apiKey),
          );
        }
        final chunkUsage = decoded['usage'];
        if (chunkUsage is Map) usage = asMap(chunkUsage);
        final choices = decoded['choices'];
        if (choices is! List) continue;
        for (final choice in choices) {
          if (choice is! Map) continue;
          final delta = choice['delta'] ?? choice['message'];
          if (delta is! Map) continue;
          final text = _textFrom(delta['content']);
          if (text.isNotEmpty) {
            textBuffer.write(text);
            callbacks.onText(text);
          }
          final reasoning = _textFrom(
            delta['reasoning_content'] ?? delta['reasoning'] ?? delta['thinking'],
          );
          if (reasoning.isNotEmpty) {
            reasoningBuffer.write(reasoning);
            callbacks.onReasoning(reasoning);
          }
          final toolCalls = delta['tool_calls'];
          if (toolCalls is List) {
            for (final raw in toolCalls) {
              if (raw is! Map) continue;
              final index = asInt(raw['index']);
              final acc = toolAcc.putIfAbsent(index, _OpenAiToolAcc.new);
              final id = raw['id'];
              if (id is String && id.isNotEmpty) acc.id = id;
              final function = raw['function'];
              if (function is Map) {
                final name = function['name'];
                if (name is String && name.isNotEmpty) acc.name = name;
                final args = function['arguments'];
                if (args != null) acc.arguments.write(_textFrom(args));
              }
            }
          }
          final legacyFunction = delta['function_call'];
          if (legacyFunction is Map) {
            final acc = toolAcc.putIfAbsent(0, _OpenAiToolAcc.new);
            final name = legacyFunction['name'];
            if (name is String && name.isNotEmpty) acc.name = name;
            final args = legacyFunction['arguments'];
            if (args != null) acc.arguments.write(_textFrom(args));
          }
        }
      }
      if (!sawDone && cancelToken.isCancelled) throw CancelledException();
      final toolCalls = _finishOpenAiTools(toolAcc);
      if (textBuffer.isEmpty && reasoningBuffer.isEmpty && toolCalls.isEmpty) {
        throw ProviderException(null, '接口返回了空响应。');
      }
      return ProviderResult(
        text: textBuffer.toString(),
        reasoning: reasoningBuffer.toString(),
        toolCalls: toolCalls,
        providerRaw: const [],
        stopReason: toolCalls.isNotEmpty ? 'tool_calls' : 'stop',
        usage: usage,
      );
    } on ProviderException {
      rethrow;
    } on CancelledException {
      rethrow;
    } on TimeoutException {
      throw ProviderException(null, '请求超时。');
    } catch (error) {
      if (cancelToken.isCancelled) throw CancelledException();
      throw ProviderException(
        null,
        friendlyHttpError(null, scrubSecret('$error', apiKey)),
      );
    } finally {
      client.close();
    }
  }

  ProviderResult _parseOpenAiCompletion(
    String body,
    String apiKey,
    StreamCallbacks callbacks,
  ) {
    final decoded = _tryJson(body);
    if (decoded is! Map) {
      throw ProviderException(null, '接口返回了无法解析的响应。');
    }
    final error = decoded['error'];
    if (error != null) {
      final message = error is Map
          ? error['message'] ?? error['detail'] ?? error['type']
          : error;
      throw ProviderException(
        null,
        scrubSecret(message is String ? message : '$message', apiKey),
      );
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw ProviderException(null, '接口返回了空响应。');
    }
    final choice = choices.first;
    final message = choice is Map ? choice['message'] : null;
    if (message is! Map) {
      throw ProviderException(null, '接口返回了无法解析的响应。');
    }
    final text = _textFrom(message['content']);
    final reasoning = _textFrom(
      message['reasoning_content'] ?? message['reasoning'] ?? message['thinking'],
    );
    if (text.isNotEmpty) callbacks.onText(text);
    if (reasoning.isNotEmpty) callbacks.onReasoning(reasoning);
    final tools = <ToolCall>[];
    final rawTools = message['tool_calls'];
    if (rawTools is List) {
      for (final raw in rawTools) {
        if (raw is! Map) continue;
        final function = raw['function'];
        if (function is! Map) continue;
        final name = asString(function['name']);
        final args = asString(function['arguments'], '{}');
        if (name.isEmpty) continue;
        tools.add(
          ToolCall(
            id: asString(raw['id'], newToolId()),
            name: name,
            argumentsJson: args,
          ),
        );
      }
    }
    return ProviderResult(
      text: text,
      reasoning: reasoning,
      toolCalls: tools,
      providerRaw: const [],
      stopReason: tools.isNotEmpty ? 'tool_calls' : 'stop',
      usage: decoded['usage'] is Map ? asMap(decoded['usage']) : null,
    );
  }

  Future<ProviderResult> _streamAnthropic({
    required ProviderAccount account,
    required ModelInfo model,
    required String apiKey,
    required List<Turn> turns,
    required Map<String, ImagePayload> images,
    required Set<String> recentImageIds,
    required String systemPrompt,
    required AppSettings settings,
    required List<ToolDefinition> tools,
    required StreamCallbacks callbacks,
    required CancelToken cancelToken,
  }) async {
    final messages = _anthropicMessages(
      turns: turns,
      images: images,
      recentImageIds: recentImageIds,
    );
    var useThinking = settings.showReasoning && model.supportsReasoning;
    var emitted = false;

    Future<ProviderResult> attempt() async {
      final payload = <String, dynamic>{
        'model': model.modelId,
        'messages': messages,
        'max_tokens': settings.maxTokens > 0 ? settings.maxTokens : 8192,
        'stream': true,
      };
      if (systemPrompt.trim().isNotEmpty) payload['system'] = systemPrompt;
      if (tools.isNotEmpty && model.supportsTools) {
        payload['tools'] = tools.map((tool) => tool.toAnthropic()).toList();
      }
      if (useThinking) {
        payload['thinking'] = {
          'type': 'adaptive',
          'display': 'summarized',
        };
      }
      return _anthropicAttempt(
        account: account,
        apiKey: apiKey,
        payload: payload,
        callbacks: StreamCallbacks(
          onText: (text) {
            emitted = true;
            callbacks.onText(text);
          },
          onReasoning: (text) {
            emitted = true;
            callbacks.onReasoning(text);
          },
        ),
        cancelToken: cancelToken,
      );
    }

    try {
      return await attempt();
    } on ProviderException catch (error) {
      if (useThinking &&
          !emitted &&
          error.status == 400 &&
          error.message.toLowerCase().contains('thinking')) {
        useThinking = false;
        return attempt();
      }
      rethrow;
    }
  }

  Future<ProviderResult> _anthropicAttempt({
    required ProviderAccount account,
    required String apiKey,
    required Map<String, dynamic> payload,
    required StreamCallbacks callbacks,
    required CancelToken cancelToken,
  }) async {
    final client = _clientFactory();
    _bindCancel(cancelToken, client);
    try {
      final request = http.Request(
        'POST',
        Uri.parse(anthropicMessagesUrl(account.baseUrl)),
      )
        ..headers.addAll({
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
          'accept': 'text/event-stream',
        })
        ..body = jsonEncode(payload);
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode >= 400) {
        final body = await response.stream.bytesToString();
        throw ProviderException(
          response.statusCode,
          friendlyHttpError(
            response.statusCode,
            errorDetailFromBody(body, apiKey),
          ),
        );
      }

      final contentType = response.headers['content-type'] ?? '';
      if (!contentType.toLowerCase().contains('text/event-stream')) {
        final body = await response.stream.bytesToString();
        return _parseAnthropicCompletion(body, apiKey, callbacks);
      }

      final blocks = <int, _AnthropicBlockAcc>{};
      final textBuffer = StringBuffer();
      final reasoningBuffer = StringBuffer();
      Map<String, dynamic>? usage;
      var stopReason = 'stop';

      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(const Duration(seconds: 120))) {
        if (cancelToken.isCancelled) throw CancelledException();
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('event:') || trimmed.startsWith(':')) {
          continue;
        }
        if (!trimmed.startsWith('data:')) continue;
        final data = trimmed.substring(5).trim();
        final event = _tryJson(data);
        if (event is! Map) continue;
        final type = asString(event['type']);
        if (type == 'error') {
          final error = event['error'];
          final message =
              error is Map ? error['message'] ?? error['type'] : error;
          throw ProviderException(
            null,
            scrubSecret(message is String ? message : '$message', apiKey),
          );
        }
        if (type == 'message_start') {
          final message = event['message'];
          if (message is Map && message['usage'] is Map) {
            usage = {...?usage, ...asMap(message['usage'])};
          }
          continue;
        }
        if (type == 'content_block_start') {
          final index = asInt(event['index']);
          final block = asMap(event['content_block']);
          final acc = _AnthropicBlockAcc.fromStart(block);
          blocks[index] = acc;
          if (acc.type == 'text' && acc.text.isNotEmpty) {
            textBuffer.write(acc.text);
            callbacks.onText(acc.text);
          }
          if (acc.type == 'thinking' && acc.thinking.isNotEmpty) {
            reasoningBuffer.write(acc.thinking);
            callbacks.onReasoning(acc.thinking);
          }
          continue;
        }
        if (type == 'content_block_delta') {
          final index = asInt(event['index']);
          final acc = blocks.putIfAbsent(index, _AnthropicBlockAcc.empty);
          final delta = asMap(event['delta']);
          final deltaType = asString(delta['type']);
          if (deltaType == 'text_delta') {
            final text = asString(delta['text']);
            if (text.isNotEmpty) {
              acc.text += text;
              textBuffer.write(text);
              callbacks.onText(text);
            }
          } else if (deltaType == 'thinking_delta') {
            final text = asString(delta['thinking']);
            if (text.isNotEmpty) {
              acc.thinking += text;
              reasoningBuffer.write(text);
              callbacks.onReasoning(text);
            }
          } else if (deltaType == 'signature_delta') {
            acc.signature += asString(delta['signature']);
          } else if (deltaType == 'input_json_delta') {
            acc.inputJson += asString(delta['partial_json']);
          }
          continue;
        }
        if (type == 'content_block_stop') {
          final index = asInt(event['index']);
          blocks[index]?.finalizeTool();
          continue;
        }
        if (type == 'message_delta') {
          final delta = asMap(event['delta']);
          if (delta['stop_reason'] is String) {
            stopReason = asString(delta['stop_reason']);
          }
          if (event['usage'] is Map) {
            usage = {...?usage, ...asMap(event['usage'])};
          }
          continue;
        }
        if (type == 'message_stop') break;
      }
      if (cancelToken.isCancelled) throw CancelledException();

      final ordered = blocks.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final providerRaw = <Map<String, dynamic>>[];
      final toolCalls = <ToolCall>[];
      for (final entry in ordered) {
        final acc = entry.value;
        if (acc.type == 'text' && acc.text.isEmpty) continue;
        if (acc.type == 'thinking' && acc.thinking.isEmpty) continue;
        if (acc.type == 'tool_use') {
          if (acc.toolName.isEmpty) continue;
          final input = acc.parsedInput();
          toolCalls.add(
            ToolCall(
              id: acc.toolId.isEmpty ? newToolId() : acc.toolId,
              name: acc.toolName,
              argumentsJson: jsonEncode(input),
            ),
          );
          providerRaw.add({
            'type': 'tool_use',
            'id': acc.toolId,
            'name': acc.toolName,
            'input': input,
          });
        } else if (acc.type == 'thinking') {
          providerRaw.add({
            'type': 'thinking',
            'thinking': acc.thinking,
            'signature': acc.signature,
          });
        } else if (acc.type == 'text') {
          providerRaw.add({'type': 'text', 'text': acc.text});
        }
      }
      if (textBuffer.isEmpty && reasoningBuffer.isEmpty && toolCalls.isEmpty) {
        throw ProviderException(null, '接口返回了空响应。');
      }
      return ProviderResult(
        text: textBuffer.toString(),
        reasoning: reasoningBuffer.toString(),
        toolCalls: toolCalls,
        providerRaw: providerRaw,
        stopReason: stopReason,
        usage: usage,
      );
    } on ProviderException {
      rethrow;
    } on CancelledException {
      rethrow;
    } on TimeoutException {
      throw ProviderException(null, '请求超时。');
    } catch (error) {
      if (cancelToken.isCancelled) throw CancelledException();
      throw ProviderException(
        null,
        friendlyHttpError(null, scrubSecret('$error', apiKey)),
      );
    } finally {
      client.close();
    }
  }

  ProviderResult _parseAnthropicCompletion(
    String body,
    String apiKey,
    StreamCallbacks callbacks,
  ) {
    final decoded = _tryJson(body);
    if (decoded is! Map) {
      throw ProviderException(null, '接口返回了无法解析的响应。');
    }
    final error = decoded['error'];
    if (error != null) {
      final message =
          error is Map ? error['message'] ?? error['type'] : error;
      throw ProviderException(
        null,
        scrubSecret(message is String ? message : '$message', apiKey),
      );
    }
    final content = decoded['content'];
    final providerRaw = <Map<String, dynamic>>[];
    final toolCalls = <ToolCall>[];
    final text = StringBuffer();
    final reasoning = StringBuffer();
    if (content is List) {
      for (final item in content) {
        if (item is! Map) continue;
        final type = asString(item['type']);
        if (type == 'text') {
          final value = asString(item['text']);
          text.write(value);
          if (value.isNotEmpty) callbacks.onText(value);
          providerRaw.add({'type': 'text', 'text': value});
        } else if (type == 'thinking') {
          final value = asString(item['thinking']);
          reasoning.write(value);
          if (value.isNotEmpty) callbacks.onReasoning(value);
          providerRaw.add({
            'type': 'thinking',
            'thinking': value,
            'signature': asString(item['signature']),
          });
        } else if (type == 'tool_use') {
          final id = asString(item['id']);
          final name = asString(item['name']);
          final input = asMap(item['input']);
          toolCalls.add(
            ToolCall(
              id: id,
              name: name,
              argumentsJson: jsonEncode(input),
            ),
          );
          providerRaw.add({
            'type': 'tool_use',
            'id': id,
            'name': name,
            'input': input,
          });
        }
      }
    }
    return ProviderResult(
      text: text.toString(),
      reasoning: reasoning.toString(),
      toolCalls: toolCalls,
      providerRaw: providerRaw,
      stopReason: asString(decoded['stop_reason'], 'stop'),
      usage: decoded['usage'] is Map ? asMap(decoded['usage']) : null,
    );
  }

  // ---------------------------------------------------------------- messages
  List<Map<String, dynamic>> _openAiMessages({
    required List<Turn> turns,
    required Map<String, ImagePayload> images,
    required Set<String> recentImageIds,
  }) {
    final result = <Map<String, dynamic>>[];
    for (final turn in turns) {
      if (turn.deleted) continue;
      if (turn.role == TurnRole.user) {
        final parts = <Map<String, dynamic>>[];
        if (turn.text.isNotEmpty) {
          parts.add({'type': 'text', 'text': turn.text});
        }
        for (final block in turn.images) {
          final id = block.attachmentId;
          if (id == null || !recentImageIds.contains(id)) continue;
          final image = images[id];
          if (image == null) continue;
          parts.add({
            'type': 'image_url',
            'image_url': {
              'url': 'data:${image.mimeType};base64,${base64Encode(image.bytes)}',
            },
          });
        }
        if (parts.isEmpty) continue;
        result.add({
          'role': 'user',
          'content': parts.length == 1 && parts.first['type'] == 'text'
              ? parts.first['text']
              : parts,
        });
        continue;
      }
      if (turn.role == TurnRole.assistant) {
        final calls = turn.toolCalls;
        if (turn.text.isEmpty && calls.isEmpty) continue;
        final message = <String, dynamic>{
          'role': 'assistant',
          'content': turn.text.isEmpty ? null : turn.text,
        };
        if (calls.isNotEmpty) {
          message['tool_calls'] = calls
              .map(
                (call) => {
                  'id': call.id,
                  'type': 'function',
                  'function': {
                    'name': call.name,
                    'arguments': call.argumentsJson,
                  },
                },
              )
              .toList();
        }
        result.add(message);
        continue;
      }
      if (turn.role == TurnRole.tool) {
        for (final block in turn.toolResults) {
          final content = (block.result ?? '').trim();
          result.add({
            'role': 'tool',
            'tool_call_id': block.toolCallId ?? '',
            'content': content.isEmpty ? '(no output)' : content,
          });
        }
      }
    }
    return result;
  }

  List<Map<String, dynamic>> _anthropicMessages({
    required List<Turn> turns,
    required Map<String, ImagePayload> images,
    required Set<String> recentImageIds,
  }) {
    final result = <Map<String, dynamic>>[];

    void append(String role, List<Map<String, dynamic>> content) {
      if (content.isEmpty) return;
      if (result.isNotEmpty && result.last['role'] == role) {
        final existing = result.last['content'];
        if (existing is List) {
          existing.addAll(content);
          return;
        }
      }
      result.add({'role': role, 'content': content});
    }

    for (final turn in turns) {
      if (turn.deleted) continue;
      if (turn.role == TurnRole.user) {
        final content = <Map<String, dynamic>>[];
        for (final block in turn.images) {
          final id = block.attachmentId;
          if (id == null || !recentImageIds.contains(id)) continue;
          final image = images[id];
          if (image == null) continue;
          content.add({
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': image.mimeType,
              'data': base64Encode(image.bytes),
            },
          });
        }
        if (turn.text.isNotEmpty) {
          content.add({'type': 'text', 'text': turn.text});
        }
        append('user', content);
        continue;
      }
      if (turn.role == TurnRole.assistant) {
        final content = <Map<String, dynamic>>[];
        if (turn.providerRaw.isNotEmpty) {
          for (final block in turn.providerRaw) {
            final type = asString(block['type']);
            if (type == 'thinking' && asString(block['signature']).isEmpty) {
              continue;
            }
            content.add(Map<String, dynamic>.from(block));
          }
        } else {
          if (turn.text.isNotEmpty) {
            content.add({'type': 'text', 'text': turn.text});
          }
          for (final call in turn.toolCalls) {
            content.add({
              'type': 'tool_use',
              'id': call.id,
              'name': call.name,
              'input': call.arguments(),
            });
          }
        }
        append('assistant', content);
        continue;
      }
      if (turn.role == TurnRole.tool) {
        final content = <Map<String, dynamic>>[];
        for (final block in turn.toolResults) {
          final value = (block.result ?? '').trim();
          content.add({
            'type': 'tool_result',
            'tool_use_id': block.toolCallId ?? '',
            'content': value.isEmpty ? '(no output)' : value,
            if (block.isError) 'is_error': true,
          });
        }
        append('user', content);
      }
    }
    return result;
  }

  Set<String> _recentImageIds(List<Turn> turns, {int maxUserTurns = 6}) {
    final allowed = <String>{};
    var userTurns = 0;
    for (final turn in turns.reversed) {
      if (turn.deleted) continue;
      if (turn.role == TurnRole.user) {
        userTurns++;
        if (userTurns > maxUserTurns) break;
      }
      for (final block in turn.images) {
        if (block.attachmentId != null) allowed.add(block.attachmentId!);
      }
    }
    return allowed;
  }

  void _bindCancel(CancelToken? token, http.Client client) {
    token?.onCancel(() {
      try {
        client.close();
      } catch (_) {
        // Ignore double-close.
      }
    });
  }
}

class _OpenAiToolAcc {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();
}

List<ToolCall> _finishOpenAiTools(Map<int, _OpenAiToolAcc> accumulators) {
  final entries = accumulators.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  final calls = <ToolCall>[];
  for (final entry in entries) {
    final acc = entry.value;
    if (acc.name.isEmpty) continue;
    calls.add(
      ToolCall(
        id: acc.id.isEmpty ? newToolId() : acc.id,
        name: acc.name,
        argumentsJson: acc.arguments.isEmpty ? '{}' : acc.arguments.toString(),
      ),
    );
  }
  return calls;
}

class _AnthropicBlockAcc {
  _AnthropicBlockAcc.empty()
      : type = '',
        text = '',
        thinking = '',
        signature = '',
        toolId = '',
        toolName = '',
        inputJson = '';
  _AnthropicBlockAcc({
    required this.type,
    this.text = '',
    this.thinking = '',
    this.signature = '',
    this.toolId = '',
    this.toolName = '',
    this.inputJson = '',
  });

  factory _AnthropicBlockAcc.fromStart(Map<String, dynamic> block) {
    final type = asString(block['type']);
    final acc = _AnthropicBlockAcc(type: type);
    if (type == 'text') {
      acc.text = asString(block['text']);
    } else if (type == 'thinking') {
      acc.thinking = asString(block['thinking']);
      acc.signature = asString(block['signature']);
    } else if (type == 'tool_use') {
      acc.toolId = asString(block['id']);
      acc.toolName = asString(block['name']);
      final input = block['input'];
      if (input is Map && input.isNotEmpty) acc.inputJson = jsonEncode(input);
    }
    return acc;
  }

  final String type;
  String text;
  String thinking;
  String signature;
  String toolId;
  String toolName;
  String inputJson;

  void finalizeTool() {
    if (type != 'tool_use') return;
    if (inputJson.trim().isEmpty) inputJson = '{}';
  }

  Map<String, dynamic> parsedInput() {
    final decoded = _tryJson(inputJson);
    return decoded is Map ? asMap(decoded) : <String, dynamic>{};
  }
}

String _textFrom(dynamic value) {
  if (value is String) return value;
  if (value is List) {
    final buffer = StringBuffer();
    for (final item in value) {
      if (item is String) {
        buffer.write(item);
      } else if (item is Map) {
        final part = item['text'] ?? item['content'];
        if (part is String) buffer.write(part);
      }
    }
    return buffer.toString();
  }
  if (value is Map) {
    for (final key in ['content', 'text', 'thinking', 'reasoning']) {
      final part = value[key];
      if (part is String) return part;
    }
  }
  return '';
}

dynamic _tryJson(String source) {
  try {
    return jsonDecode(source);
  } catch (_) {
    return null;
  }
}

String newToolId() =>
    'call_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
