import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/models.dart';
import '../providers/provider_common.dart';

class WebSearchService {
  WebSearchService({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;

  Future<String> search({
    required String query,
    required SearchProvider provider,
    required int maxResults,
    String? tavilyKey,
    String? braveKey,
  }) async {
    final limit = maxResults.clamp(1, 10);
    switch (provider) {
      case SearchProvider.tavily:
        if (tavilyKey == null || tavilyKey.isEmpty) {
          throw ProviderException(null, '请先在设置中填写 Tavily API Key。');
        }
        return _tavily(query, limit, tavilyKey);
      case SearchProvider.brave:
        if (braveKey == null || braveKey.isEmpty) {
          throw ProviderException(null, '请先在设置中填写 Brave API Key。');
        }
        return _brave(query, limit, braveKey);
      case SearchProvider.duckduckgo:
        return _duckDuckGo(query, limit);
    }
  }

  Future<String> _tavily(String query, int limit, String key) async {
    final client = _clientFactory();
    try {
      final response = await client
          .post(
            Uri.parse('https://api.tavily.com/search'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'api_key': key,
              'query': query,
              'max_results': limit,
              'search_depth': 'basic',
              'include_answer': false,
            }),
          )
          .timeout(const Duration(seconds: 25));
      if (response.statusCode >= 400) {
        throw ProviderException(
          response.statusCode,
          friendlyHttpError(
            response.statusCode,
            errorDetailFromBody(utf8.decode(response.bodyBytes), key),
          ),
        );
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final results = <Map<String, dynamic>>[];
      if (decoded is Map && decoded['results'] is List) {
        for (final item in decoded['results'] as List) {
          if (item is! Map) continue;
          results.add({
            'title': item['title'] ?? '',
            'url': item['url'] ?? '',
            'snippet': item['content'] ?? item['snippet'] ?? '',
          });
        }
      }
      return _encode(query, results);
    } finally {
      client.close();
    }
  }

  Future<String> _brave(String query, int limit, String key) async {
    final client = _clientFactory();
    try {
      final uri = Uri.https(
        'api.search.brave.com',
        '/res/v1/web/search',
        {'q': query, 'count': '$limit'},
      );
      final response = await client.get(
        uri,
        headers: {
          'Accept': 'application/json',
          'X-Subscription-Token': key,
        },
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode >= 400) {
        throw ProviderException(
          response.statusCode,
          friendlyHttpError(
            response.statusCode,
            errorDetailFromBody(utf8.decode(response.bodyBytes), key),
          ),
        );
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final results = <Map<String, dynamic>>[];
      if (decoded is Map && decoded['web'] is Map) {
        final web = decoded['web'];
        if (web is Map && web['results'] is List) {
          for (final item in web['results'] as List) {
            if (item is! Map) continue;
            results.add({
              'title': item['title'] ?? '',
              'url': item['url'] ?? '',
              'snippet': item['description'] ?? '',
            });
          }
        }
      }
      return _encode(query, results);
    } finally {
      client.close();
    }
  }

  Future<String> _duckDuckGo(String query, int limit) async {
    final client = _clientFactory();
    try {
      final uri = Uri.https('html.duckduckgo.com', '/html/', {'q': query});
      final response = await client.get(
        uri,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
        },
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode >= 400) {
        throw ProviderException(
          response.statusCode,
          friendlyHttpError(response.statusCode),
        );
      }
      final document = html_parser.parse(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      final results = <Map<String, dynamic>>[];
      for (final element in document.querySelectorAll('.result')) {
        if (results.length >= limit) break;
        final anchor = element.querySelector('a.result__a');
        if (anchor == null) continue;
        var url = anchor.attributes['href'] ?? '';
        if (url.startsWith('//duckduckgo.com/l/')) {
          final parsed = Uri.tryParse('https:$url');
          url = parsed?.queryParameters['uddg'] ?? url;
        }
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
          continue;
        }
        final snippet =
            element.querySelector('.result__snippet')?.text.trim() ?? '';
        results.add({
          'title': anchor.text.trim(),
          'url': url,
          'snippet': snippet,
        });
      }
      if (results.isEmpty) {
        throw ProviderException(null, 'DuckDuckGo 没有返回可解析的结果。');
      }
      return _encode(query, results);
    } finally {
      client.close();
    }
  }

  String _encode(String query, List<Map<String, dynamic>> results) =>
      const JsonEncoder.withIndent('  ').convert({
        'query': query,
        'results': results,
      });
}
