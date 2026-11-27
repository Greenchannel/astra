import 'dart:io';

import 'package:astra_gui/data/storage/json_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('JSON store writes and reads atomically', () async {
    final dir = await Directory.systemTemp.createTemp('astra-json-test-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final store = JsonStore(dir);
    await store.write('settings.json', {'theme': 'dark', 'value': 3});
    final loaded = await store.read('settings.json');
    expect(loaded, isA<Map>());
    expect((loaded as Map)['theme'], 'dark');
  });

  test('corrupt JSON is backed up and null is returned', () async {
    final dir = await Directory.systemTemp.createTemp('astra-json-corrupt-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final store = JsonStore(dir);
    await File('${dir.path}/broken.json').writeAsString('{not json');
    expect(await store.read('broken.json'), isNull);
    final backups = dir
        .listSync()
        .where((entry) => entry.path.contains('.corrupt-'))
        .toList();
    expect(backups, isNotEmpty);
  });
}
