import 'dart:convert';
import 'dart:io';

class JsonStore {
  JsonStore(this.root);

  final Directory root;

  Future<dynamic> read(String name) async {
    final file = File('${root.path}${Platform.pathSeparator}$name');
    if (!await file.exists()) return null;
    try {
      final text = await file.readAsString();
      if (text.trim().isEmpty) return null;
      return jsonDecode(text);
    } catch (_) {
      // Keep the damaged file for manual recovery instead of silently losing it.
      try {
        final backup = '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}';
        await file.copy(backup);
      } catch (_) {
        // Best effort only.
      }
      return null;
    }
  }

  Future<void> write(String name, Object? value) async {
    final file = File('${root.path}${Platform.pathSeparator}$name');
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(value),
      flush: true,
    );
    try {
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
    } catch (_) {
      // Fallback for platforms where rename-over-existing is restricted.
      await temp.copy(file.path);
      await temp.delete();
    }
  }

  Future<void> writeBytes(String name, List<int> bytes) async {
    final file = File('${root.path}${Platform.pathSeparator}$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<List<int>?> readBytes(String name) async {
    final file = File('${root.path}${Platform.pathSeparator}$name');
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }
}
