import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../util/json.dart';
import '../models/models.dart';

/// Runs Python and shell commands locally.
///
/// Android delegates to the Chaquopy bridge; desktop launches a child process
/// with a scrubbed environment and a per-conversation working directory.
class PythonRuntime {
  static const _channel = MethodChannel('astra/python');
  static const _maxOutput = 20000;

  bool get available =>
      Platform.isAndroid ||
      Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS;

  bool get desktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Future<ToolExecutionResult> runPython({
    required String code,
    required Directory workspace,
    required String pythonPath,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod<Map<Object?, Object?>>(
          'run',
          {
            'code': code,
            'workspace': workspace.path,
            'timeoutMs': timeout.inMilliseconds,
          },
        ).timeout(timeout + const Duration(seconds: 8));
        return _mapAndroidResult(result);
      } on TimeoutException {
        return ToolExecutionResult.error('Android Python 执行超时。');
      } on MissingPluginException {
        return ToolExecutionResult.error(
          '此 Android 构建没有启用 Chaquopy Python 运行时。',
        );
      } on PlatformException catch (error) {
        return ToolExecutionResult.error(
          'Android Python 错误：${error.message ?? error.code}',
        );
      }
    }
    if (!desktop) {
      return ToolExecutionResult.error('当前平台不支持 Python 工具。');
    }
    final file = File(
      '${workspace.path}${Platform.pathSeparator}astra_snippet_'
      '${DateTime.now().microsecondsSinceEpoch}.py',
    );
    await file.writeAsString(code, flush: true);
    try {
      return await _runProcess(
        executable: pythonPath,
        arguments: ['-I', file.path],
        workspace: workspace,
        timeout: timeout,
      );
    } finally {
      try {
        await file.delete();
      } catch (_) {
        // Best effort cleanup.
      }
    }
  }

  Future<ToolExecutionResult> runShell({
    required String command,
    required Directory workspace,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!desktop) {
      return ToolExecutionResult.error('Shell 工具仅在桌面端可用。');
    }
    final executable = Platform.isWindows ? 'cmd.exe' : '/bin/sh';
    final arguments = Platform.isWindows ? ['/c', command] : ['-c', command];
    return _runProcess(
      executable: executable,
      arguments: arguments,
      workspace: workspace,
      timeout: timeout,
    );
  }

  Future<ToolExecutionResult> _runProcess({
    required String executable,
    required List<String> arguments,
    required Directory workspace,
    required Duration timeout,
  }) async {
    Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        workingDirectory: workspace.path,
        includeParentEnvironment: false,
        environment: _safeEnvironment(workspace),
      );
    } catch (error) {
      return ToolExecutionResult.error(
        '无法启动 $executable：$error',
      );
    }

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    var timedOut = false;
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {
        process.kill();
      }
      exitCode = -1;
    }

    final stdout = await stdoutFuture.timeout(
      const Duration(seconds: 2),
      onTimeout: () => '',
    );
    final stderr = await stderrFuture.timeout(
      const Duration(seconds: 2),
      onTimeout: () => '',
    );
    final buffer = StringBuffer();
    if (stdout.trim().isNotEmpty) {
      buffer.writeln('stdout:');
      buffer.writeln(_truncate(stdout.trim()));
    }
    if (stderr.trim().isNotEmpty) {
      buffer.writeln('stderr:');
      buffer.writeln(_truncate(stderr.trim()));
    }
    buffer.writeln('exit code: $exitCode${timedOut ? ' (timeout)' : ''}');
    return ToolExecutionResult(
      content: _truncate(buffer.toString().trim()),
      isError: timedOut || exitCode != 0,
    );
  }

  Map<String, String> _safeEnvironment(Directory workspace) {
    final env = <String, String>{
      'PYTHONIOENCODING': 'utf-8',
      'HOME': workspace.path,
      'TMPDIR': workspace.path,
      'TEMP': workspace.path,
      'TMP': workspace.path,
    };
    final path = Platform.environment['PATH'];
    if (path != null) env['PATH'] = path;
    final systemRoot = Platform.environment['SystemRoot'];
    if (systemRoot != null) env['SystemRoot'] = systemRoot;
    final windir = Platform.environment['WINDIR'];
    if (windir != null) env['WINDIR'] = windir;
    return env;
  }

  ToolExecutionResult _mapAndroidResult(Map<Object?, Object?>? raw) {
    final map = asMap(raw);
    final stdout = asString(map['stdout']);
    final stderr = asString(map['stderr']);
    final exitCode = asInt(map['exitCode']);
    final timedOut = asBool(map['timedOut']);
    final buffer = StringBuffer();
    if (stdout.trim().isNotEmpty) {
      buffer.writeln('stdout:');
      buffer.writeln(_truncate(stdout.trim()));
    }
    if (stderr.trim().isNotEmpty) {
      buffer.writeln('stderr:');
      buffer.writeln(_truncate(stderr.trim()));
    }
    buffer.writeln(
      'exit code: $exitCode${timedOut ? ' (timeout)' : ''}',
    );
    return ToolExecutionResult(
      content: _truncate(buffer.toString().trim()),
      isError: timedOut || exitCode != 0,
    );
  }

  String _truncate(String text) => text.length > _maxOutput
      ? '${text.substring(0, _maxOutput)}\n…(output truncated)'
      : text;
}
