import 'dart:io';

import '../../util/json.dart';
import '../models/models.dart';
import '../platform/python_runtime.dart';
import 'web_search_tool.dart';

class ToolContext {
  const ToolContext({
    required this.workspace,
    required this.settings,
    this.tavilyKey,
    this.braveKey,
  });

  final Directory workspace;
  final AppSettings settings;
  final String? tavilyKey;
  final String? braveKey;
}

class ToolRegistry {
  ToolRegistry({
    required this.pythonRuntime,
    required this.webSearch,
  });

  final PythonRuntime pythonRuntime;
  final WebSearchService webSearch;

  List<ToolDefinition> definitionsFor(AppSettings settings) {
    final tools = <ToolDefinition>[];
    if (settings.enableWebSearch) {
      tools.add(
        const ToolDefinition(
          name: 'web_search',
          description:
              'Search the live web. Use it for current facts, news, prices, '
              'documentation or anything that may have changed. Cite result URLs '
              'in the final answer.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'query': {
                'type': 'string',
                'description': 'Search query, in the user language.',
              },
              'max_results': {
                'type': 'integer',
                'minimum': 1,
                'maximum': 10,
                'description': 'Number of results to return.',
              },
            },
            'required': ['query'],
            'additionalProperties': false,
          },
          requiresApproval: false,
        ),
      );
    }
    if (settings.enableCodeTools && pythonRuntime.available) {
      tools.add(
        const ToolDefinition(
          name: 'run_python',
          description:
              'Run a short Python 3 snippet in a private workspace on this '
              'device and return stdout/stderr. Use the standard library; '
              'do not assume notebook state between calls.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'code': {
                'type': 'string',
                'description': 'Complete Python code to execute.',
              },
            },
            'required': ['code'],
            'additionalProperties': false,
          },
          requiresApproval: true,
        ),
      );
    }
    if (settings.enableShellTool && pythonRuntime.desktop) {
      tools.add(
        const ToolDefinition(
          name: 'run_shell',
          description:
              'Run a shell command in the conversation workspace. This is a '
              'high-risk desktop-only tool and always requires approval.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'command': {
                'type': 'string',
                'description': 'Command line to execute.',
              },
            },
            'required': ['command'],
            'additionalProperties': false,
          },
          requiresApproval: true,
        ),
      );
    }
    return tools;
  }

  bool requiresApproval(String name) {
    switch (name) {
      case 'run_python':
      case 'run_shell':
        return true;
      default:
        return false;
    }
  }

  Future<ToolExecutionResult> execute(
    ToolCall call,
    ToolContext context,
  ) async {
    final arguments = call.arguments();
    try {
      switch (call.name) {
        case 'web_search':
          final query = asString(arguments['query']).trim();
          if (query.isEmpty) {
            return ToolExecutionResult.error('search query is empty');
          }
          final requested = asInt(
            arguments['max_results'],
            context.settings.searchResultCount,
          );
          final result = await webSearch.search(
            query: query,
            provider: context.settings.searchProvider,
            maxResults: requested,
            tavilyKey: context.tavilyKey,
            braveKey: context.braveKey,
          );
          return ToolExecutionResult(content: result);
        case 'run_python':
          final code = asString(arguments['code']);
          if (code.trim().isEmpty) {
            return ToolExecutionResult.error('python code is empty');
          }
          return pythonRuntime.runPython(
            code: code,
            workspace: context.workspace,
            pythonPath: context.settings.pythonPath,
          );
        case 'run_shell':
          final command = asString(arguments['command']);
          if (command.trim().isEmpty) {
            return ToolExecutionResult.error('shell command is empty');
          }
          return pythonRuntime.runShell(
            command: command,
            workspace: context.workspace,
          );
        default:
          return ToolExecutionResult.error('unknown tool: ${call.name}');
      }
    } catch (error) {
      return ToolExecutionResult.error('tool failed: $error');
    }
  }
}
