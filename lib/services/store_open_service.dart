import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/attachment_data.dart';
import '../storage/store_protocol.dart';
import '../storage/store_uri_reader.dart';
import '../widgets/store_file_preview.dart';
import 'logger_service.dart';

/// Opens / previews `store://` files for chat UI.
///
/// Reads via [StoreUriReader] (files + artifacts + own private spaces), then:
/// - images / text → in-app preview sheet
/// - other types → materialize under temp and [OpenFile.open]
class StoreOpenService {
  StoreOpenService._();
  static final instance = StoreOpenService._();

  static const _tag = 'StoreOpen';
  static const _maxTextPreviewBytes = 2 * 1024 * 1024;
  static const _maxImagePreviewBytes = 20 * 1024 * 1024;

  final _log = LoggerService();

  /// Open a `store://…` URI from a markdown link or attachment metadata.
  Future<void> openStoreUri(BuildContext context, String uriString) async {
    try {
      final parsed = parseStoreUri(uriString);
      final name = p.basename(parsed.path);
      final bytes = await StoreUriReader.instance.read(uriString);
      if (!context.mounted) return;
      await _present(context, fileName: name, bytes: bytes);
    } catch (e) {
      _log.warning('openStoreUri failed: $e', tag: _tag, error: e);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cannot open: $uriString')),
        );
      }
    }
  }

  /// Open from chat attachment metadata (`store_uri` preferred).
  Future<void> openFromMetadata(
    BuildContext context,
    Map<String, dynamic>? metadata,
  ) async {
    final storeUri = metadata?['store_uri'] as String?;
    if (storeUri != null && storeUri.isNotEmpty) {
      await openStoreUri(context, storeUri);
      return;
    }
    final name = metadata?['name'] as String? ?? 'file';
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No store:// URI for $name')),
      );
    }
  }

  Future<void> _present(
    BuildContext context, {
    required String fileName,
    required Uint8List bytes,
  }) async {
    final kind = _previewKind(fileName);
    if (kind == _PreviewKind.image && bytes.length <= _maxImagePreviewBytes) {
      await StoreFilePreview.showImage(
        context,
        fileName: fileName,
        bytes: bytes,
      );
      return;
    }
    if (kind == _PreviewKind.text && bytes.length <= _maxTextPreviewBytes) {
      late final String text;
      try {
        text = utf8.decode(bytes);
      } catch (_) {
        await materializeAndOpen(fileName, bytes);
        return;
      }
      if (!context.mounted) return;
      await StoreFilePreview.showText(
        context,
        fileName: fileName,
        text: text,
        bytes: bytes,
        asMarkdown: fileName.toLowerCase().endsWith('.md') ||
            fileName.toLowerCase().endsWith('.markdown'),
      );
      return;
    }
    await materializeAndOpen(fileName, bytes);
  }

  /// Write [bytes] under temp and open with the system default app.
  Future<OpenResult> materializeAndOpen(
    String fileName,
    Uint8List bytes,
  ) async {
    final dir = await getTemporaryDirectory();
    final safe = AttachmentData.safeFileName(fileName);
    final file = File(p.join(dir.path, 'shepaw_store_$safe'));
    await file.writeAsBytes(bytes, flush: true);
    final result = await OpenFile.open(file.path);
    if (result.type != ResultType.done) {
      _log.warning(
        'OpenFile ${result.type}: ${result.message} path=${file.path}',
        tag: _tag,
      );
    }
    return result;
  }

  static _PreviewKind _previewKind(String fileName) {
    final ext = p.extension(fileName).toLowerCase();
    switch (ext) {
      case '.png':
      case '.jpg':
      case '.jpeg':
      case '.gif':
      case '.webp':
      case '.bmp':
        return _PreviewKind.image;
      case '.txt':
      case '.md':
      case '.markdown':
      case '.json':
      case '.csv':
      case '.log':
      case '.yaml':
      case '.yml':
      case '.xml':
      case '.html':
      case '.htm':
      case '.dart':
      case '.py':
      case '.js':
      case '.ts':
      case '.swift':
      case '.kt':
      case '.java':
      case '.go':
      case '.rs':
      case '.c':
      case '.h':
      case '.cpp':
      case '.cc':
      case '.css':
      case '.sh':
        return _PreviewKind.text;
      default:
        return _PreviewKind.other;
    }
  }
}

enum _PreviewKind { image, text, other }
