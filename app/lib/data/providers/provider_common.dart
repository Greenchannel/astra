import 'dart:convert';

class ProviderException implements Exception {
  ProviderException(this.status, this.message);

  final int? status;
  final String message;

  @override
  String toString() => message;
}

class CancelledException implements Exception {}

class RemoteModel {
  const RemoteModel({required this.id, required this.displayName});

  final String id;
  final String displayName;
}

String scrubSecret(String text, String secret) {
  var result = text;
  if (secret.isNotEmpty) {
    result = result.replaceAll(secret, '[REDACTED]');
  }
  result = result.replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'), '');
  return result.length > 1200 ? '${result.substring(0, 1200)}…' : result;
}

String friendlyHttpError(int? status, [String detail = '']) {
  final String head;
  switch (status) {
    case null:
      head = '网络连接失败，请检查网络或 Base URL。';
      break;
    case 400:
      head = '请求被拒绝（参数或模型可能不受支持）。';
      break;
    case 401:
      head = '认证失败：API Key 无效或已过期。';
      break;
    case 403:
      head = '没有权限访问该模型或接口。';
      break;
    case 404:
      head = '接口或模型不存在，请检查 Base URL 与模型名。';
      break;
    case 413:
      head = '请求内容过长。';
      break;
    case 429:
      head = '请求过于频繁或额度已用尽，请稍后重试。';
      break;
    default:
      head = status >= 500
          ? '服务端错误，请稍后重试。'
          : 'API 返回错误（HTTP $status）。';
  }
  final trimmed = detail.trim();
  return trimmed.isEmpty ? head : '$head\n$trimmed';
}

String errorDetailFromBody(String body, String apiKey) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final error = decoded['error'];
      if (error is Map) {
        final message = error['message'] ?? error['detail'] ?? error['type'];
        if (message is String) return scrubSecret(message, apiKey);
      }
      if (error is String) return scrubSecret(error, apiKey);
      final message = decoded['message'] ?? decoded['detail'];
      if (message is String) return scrubSecret(message, apiKey);
    }
  } catch (_) {
    // Plain text response.
  }
  return scrubSecret(body, apiKey);
}

String normalizeOpenAiBase(String raw) {
  var url = raw.trim();
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  if (url.endsWith('/chat/completions')) {
    url = url.substring(0, url.length - '/chat/completions'.length);
  } else if (url.endsWith('/models')) {
    url = url.substring(0, url.length - '/models'.length);
  }
  return url;
}

String normalizeAnthropicBase(String raw) {
  var url = raw.trim();
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  for (final suffix in ['/v1/messages', '/messages', '/v1/models']) {
    if (url.endsWith(suffix)) {
      url = url.substring(0, url.length - suffix.length);
      while (url.endsWith('/')) {
        url = url.substring(0, url.length - 1);
      }
      break;
    }
  }
  if (url.endsWith('/v1')) {
    url = url.substring(0, url.length - 3);
  }
  return url;
}

String openAiChatUrl(String baseUrl) =>
    '${normalizeOpenAiBase(baseUrl)}/chat/completions';

String openAiModelsUrl(String baseUrl) =>
    '${normalizeOpenAiBase(baseUrl)}/models';

String anthropicMessagesUrl(String baseUrl) =>
    '${normalizeAnthropicBase(baseUrl)}/v1/messages';

String anthropicModelsUrl(String baseUrl) =>
    '${normalizeAnthropicBase(baseUrl)}/v1/models?limit=1000';
