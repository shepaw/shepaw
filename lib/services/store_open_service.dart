import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/attachment_data.dart';
import '../models/store_attachment_ref.dart';
import '../storage/device_identity.dart';
import '../storage/local_store.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import '../storage/store_uri_reader.dart';
import '../widgets/store_file_preview.dart';
import 'logger_service.dart';

/// Opens / previews `store://` files for chat UI.
///
/// Prefer cheap local paths:
/// - image/text under size caps → in-app preview ([Image.file] / text; no temp)
/// - other / oversized → [File.copy] to temp when local, else chunked write;
///   then [OpenFile.open]
///
/// Remote URIs still pay for a verified read (cache layer); materialize then
/// prefers copying the on-disk cache when available rather than rewriting
/// from an in-memory buffer twice when we only have bytes.
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
      final kind = _previewKind(name);
      final local = await StoreAttachmentRef.fileFromStoreUri(uriString);

      if (local != null) {
        if (!context.mounted) return;
        await _presentLocal(context, fileName: name, file: local, kind: kind);
        return;
      }

      // Remote / not a plain local file: preview still needs bytes; materialize
      // streams through the store read API when possible.
      if (kind == _PreviewKind.other) {
        await materializeUriAndOpen(uriString, name);
        return;
      }

      final bytes = await StoreUriReader.instance.read(uriString);
      if (!context.mounted) return;
      await _presentBytes(context, fileName: name, bytes: bytes, kind: kind);
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

  Future<void> _presentLocal(
    BuildContext context, {
    required String fileName,
    required File file,
    required _PreviewKind kind,
  }) async {
    final size = await file.length();
    if (kind == _PreviewKind.image && size <= _maxImagePreviewBytes) {
      if (!context.mounted) return;
      await StoreFilePreview.showImageFile(
        context,
        fileName: fileName,
        file: file,
      );
      return;
    }
    if (kind == _PreviewKind.text && size <= _maxTextPreviewBytes) {
      late final String text;
      try {
        text = await file.readAsString();
      } catch (_) {
        await copyAndOpen(file, fileName);
        return;
      }
      if (!context.mounted) return;
      await StoreFilePreview.showText(
        context,
        fileName: fileName,
        text: text,
        sourceFile: file,
        asMarkdown: fileName.toLowerCase().endsWith('.md') ||
            fileName.toLowerCase().endsWith('.markdown'),
      );
      return;
    }
    await copyAndOpen(file, fileName);
  }

  Future<void> _presentBytes(
    BuildContext context, {
    required String fileName,
    required Uint8List bytes,
    required _PreviewKind kind,
  }) async {
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
        await writeBytesAndOpen(fileName, bytes);
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
    await writeBytesAndOpen(fileName, bytes);
  }

  /// OS-level copy of a local store file into temp, then system open.
  Future<OpenResult> copyAndOpen(File source, String fileName) async {
    final dest = await _tempTarget(fileName);
    await source.copy(dest.path);
    return _openPath(dest.path);
  }

  /// Write already-buffered [bytes] under temp and open.
  Future<OpenResult> writeBytesAndOpen(
    String fileName,
    Uint8List bytes,
  ) async {
    final dest = await _tempTarget(fileName);
    await dest.writeAsBytes(bytes, flush: true);
    return _openPath(dest.path);
  }

  /// Materialize a URI to temp without holding the whole file in a Dart
  /// [Uint8List] when a local path or chunked local store read is available.
  Future<OpenResult> materializeUriAndOpen(
    String uriString,
    String fileName,
  ) async {
    final local = await StoreAttachmentRef.fileFromStoreUri(uriString);
    if (local != null) {
      return copyAndOpen(local, fileName);
    }

    final dest = await _tempTarget(fileName);
    final parsed = parseStoreUri(uriString);
    final self = await DeviceIdentity.deviceId();
    if (parsed.device == self) {
      await _streamLocalStoreTo(dest, parsed.device, parsed.space, parsed.path);
      return _openPath(dest.path);
    }

    // Remote verified read already buffers; reuse those bytes once.
    final bytes = await StoreUriReader.instance.read(uriString);
    await dest.writeAsBytes(bytes, flush: true);
    return _openPath(dest.path);
  }

  Future<void> _streamLocalStoreTo(
    File dest,
    String deviceId,
    String space,
    String path,
  ) async {
    final store = await StoreService.instance.localStore();
    final sink = dest.openWrite();
    try {
      var offset = 0;
      while (true) {
        final (chunk, _, eof) = await store.read(
          deviceId,
          space,
          path,
          offset,
          LocalStore.maxReadChunk,
        );
        if (chunk.isNotEmpty) sink.add(chunk);
        offset += chunk.length;
        if (eof || chunk.isEmpty) break;
      }
    } finally {
      await sink.close();
    }
  }

  Future<File> _tempTarget(String fileName) async {
    final dir = await getTemporaryDirectory();
    final safe = AttachmentData.safeFileName(fileName);
    return File(p.join(dir.path, 'shepaw_store_$safe'));
  }

  Future<OpenResult> _openPath(String path) async {
    final result = await OpenFile.open(path);
    if (result.type != ResultType.done) {
      _log.warning(
        'OpenFile ${result.type}: ${result.message} path=$path',
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
