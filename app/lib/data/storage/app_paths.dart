import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppPaths {
  AppPaths({required this.root, required this.attachments, required this.workspaces});

  final Directory root;
  final Directory attachments;
  final Directory workspaces;

  static Future<AppPaths> open() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'astra_gui'));
    final attachments = Directory(p.join(root.path, 'attachments'));
    final workspaces = Directory(p.join(root.path, 'workspaces'));
    await root.create(recursive: true);
    await attachments.create(recursive: true);
    await workspaces.create(recursive: true);
    return AppPaths(
      root: root,
      attachments: attachments,
      workspaces: workspaces,
    );
  }

  String file(String name) => p.join(root.path, name);

  String attachmentPath(String id, String extension) =>
      p.join(attachments.path, '$id.$extension');

  Future<Directory> workspaceFor(String conversationId) async {
    final dir = Directory(p.join(workspaces.path, conversationId));
    await dir.create(recursive: true);
    return dir;
  }
}
