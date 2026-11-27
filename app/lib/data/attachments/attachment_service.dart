import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class PendingImage {
  const PendingImage({
    required this.bytes,
    required this.thumbnail,
    required this.fileName,
    required this.mimeType,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final Uint8List thumbnail;
  final String fileName;
  final String mimeType;
  final int width;
  final int height;
}

class AttachmentService {
  static const maxImages = 4;
  static const maxSourceBytes = 20 * 1024 * 1024;

  Future<List<PendingImage>> pickImages() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
      dialogTitle: '选择图片',
    );
    if (result == null) return const [];
    final picked = <PendingImage>[];
    for (final file in result.files.take(maxImages)) {
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) {
        final source = File(file.path!);
        if (!await source.exists()) continue;
        bytes = await source.readAsBytes();
      }
      if (bytes == null) continue;
      if (bytes.lengthInBytes > maxSourceBytes) {
        throw AttachmentException('${file.name} 超过 20MB，已跳过。');
      }
      final prepared = await compute(_prepareImage, {
        'bytes': bytes,
        'name': file.name,
      });
      if (prepared == null) {
        throw AttachmentException('${file.name} 不是支持的图片格式。');
      }
      picked.add(
        PendingImage(
          bytes: prepared['bytes'] as Uint8List,
          thumbnail: prepared['thumbnail'] as Uint8List,
          fileName: prepared['name'] as String,
          mimeType: 'image/jpeg',
          width: prepared['width'] as int,
          height: prepared['height'] as int,
        ),
      );
    }
    return picked;
  }

  Future<String> sha256Hex(Uint8List bytes) async {
    final hash = await Sha256().hash(bytes);
    return hash.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

class AttachmentException implements Exception {
  AttachmentException(this.message);

  final String message;

  @override
  String toString() => message;
}

Map<String, dynamic>? _prepareImage(Map<String, dynamic> input) {
  final bytes = input['bytes'] as Uint8List;
  final name = input['name'] as String? ?? 'image';
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  const maxEdge = 2048;
  final longEdge = math.max(decoded.width, decoded.height);
  img.Image processed = decoded;
  if (longEdge > maxEdge) {
    final scale = maxEdge / longEdge;
    processed = img.copyResize(
      decoded,
      width: math.max(1, (decoded.width * scale).round()),
      height: math.max(1, (decoded.height * scale).round()),
      interpolation: img.Interpolation.linear,
    );
  }
  final encoded = Uint8List.fromList(img.encodeJpg(processed, quality: 85));

  const thumbEdge = 360;
  img.Image thumbSource = processed;
  final thumbLong = math.max(processed.width, processed.height);
  if (thumbLong > thumbEdge) {
    final scale = thumbEdge / thumbLong;
    thumbSource = img.copyResize(
      processed,
      width: math.max(1, (processed.width * scale).round()),
      height: math.max(1, (processed.height * scale).round()),
      interpolation: img.Interpolation.linear,
    );
  }
  final thumbnail = Uint8List.fromList(img.encodeJpg(thumbSource, quality: 78));

  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  return {
    'bytes': encoded,
    'thumbnail': thumbnail,
    'name': '$base.jpg',
    'width': processed.width,
    'height': processed.height,
  };
}
