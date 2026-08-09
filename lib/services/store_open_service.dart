import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../models/attachment_data.dart';
import '../models/store_attachment_ref.dart';
import '../storage/local_store.dart';
import '../storage/store_protocol.dart';
import '../storage/store_uri_reader.dart';
import '../storage/store_file_visual.dart';
import '../widgets/store_file_preview.dart';
import 'logger_service.dart';

/// Opens / previews `store://` files for chat UI.
///
/// Size tiers:
/// - within preview caps → in-app image/text preview
/// - above [_confirmMaterializeBytes] → confirm, then materialize with progress
/// - above [_hardLimitBytes] → refuse (no auto copy / download)
class StoreOpenService {
  StoreOpenService._();
  static final instance = StoreOpenService._();

  static const _tag = 'StoreOpen';
  static const _maxTextPreviewBytes = 2 * 1024 * 1024;
  static const _maxImagePreviewBytes = 20 * 1024 * 1024;
  /// Ask before copying / downloading into temp.
  static const confirmMaterializeBytes = 32 * 1024 * 1024;
  /// Refuse automatic open (user should use storage UI / share).
  static const hardLimitBytes = 512 * 1024 * 1024;

  final _log = LoggerService();

  /// Open a `store://…` URI from a markdown link or attachment metadata.
  Future<void> openStoreUri(BuildContext context, String uriString) async {
    try {
      final parsed = parseStoreUri(uriString);
      final name = p.basename(parsed.path);
      var kind = await _resolvePreviewKind(uriString, parsed.path, name);
      final size = await StoreUriReader.instance.sizeOf(uriString);

      if (!context.mounted) return;

      if (size > hardLimitBytes) {
        await _showTooLarge(context, name, size);
        return;
      }

      final canPreview = (kind == _PreviewKind.image &&
              size <= _maxImagePreviewBytes) ||
          (kind == _PreviewKind.text && size <= _maxTextPreviewBytes);

      if (canPreview) {
        final local = await StoreAttachmentRef.fileFromStoreUri(uriString);
        if (!context.mounted) return;
        if (local != null) {
          await _presentLocal(
            context,
            fileName: name,
            file: local,
            kind: kind,
            storeUri: uriString,
          );
          return;
        }
        final bytes = await StoreUriReader.instance.read(uriString);
        if (!context.mounted) return;
        await _presentBytes(
          context,
          fileName: name,
          bytes: bytes,
          kind: kind,
          storeUri: uriString,
        );
        return;
      }

      // Materialize path (system open).
      if (size >= confirmMaterializeBytes) {
        final ok = await _confirmLargeOpen(context, name, size);
        if (!ok || !context.mounted) return;
      }

      await materializeUriAndOpen(
        context,
        uriString,
        name,
        size: size,
        showProgress: size >= confirmMaterializeBytes,
      );
    } on StoreException catch (e) {
      _log.warning('openStoreUri failed: $e', tag: _tag, error: e);
      if (context.mounted) {
        final msg = e.code == StoreError.badOp && e.message.contains('too large')
            ? 'File too large to open here'
            : 'Cannot open: $uriString';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
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
    String? storeUri,
  }) async {
    final size = await file.length();
    if (kind == _PreviewKind.image && size <= _maxImagePreviewBytes) {
      if (!context.mounted) return;
      await StoreFilePreview.showImageFile(
        context,
        fileName: fileName,
        file: file,
        storeUri: storeUri,
      );
      return;
    }
    if (kind == _PreviewKind.text && size <= _maxTextPreviewBytes) {
      late final String text;
      try {
        text = await file.readAsString();
      } catch (_) {
        if (!context.mounted) return;
        await copyAndOpen(context, file, fileName, size: size);
        return;
      }
      if (!context.mounted) return;
      await StoreFilePreview.showText(
        context,
        fileName: fileName,
        text: text,
        sourceFile: file,
        storeUri: storeUri,
        asMarkdown: fileName.toLowerCase().endsWith('.md') ||
            fileName.toLowerCase().endsWith('.markdown'),
      );
      return;
    }
    if (!context.mounted) return;
    await copyAndOpen(context, file, fileName, size: size);
  }

  Future<void> _presentBytes(
    BuildContext context, {
    required String fileName,
    required Uint8List bytes,
    required _PreviewKind kind,
    String? storeUri,
  }) async {
    if (kind == _PreviewKind.image && bytes.length <= _maxImagePreviewBytes) {
      await StoreFilePreview.showImage(
        context,
        fileName: fileName,
        bytes: bytes,
        storeUri: storeUri,
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
        storeUri: storeUri,
        asMarkdown: fileName.toLowerCase().endsWith('.md') ||
            fileName.toLowerCase().endsWith('.markdown'),
      );
      return;
    }
    await writeBytesAndOpen(fileName, bytes);
  }

  Future<OpenResult> copyAndOpen(
    BuildContext context,
    File source,
    String fileName, {
    int? size,
  }) async {
    final n = size ?? await source.length();
    if (n > hardLimitBytes) {
      if (context.mounted) await _showTooLarge(context, fileName, n);
      return OpenResult(type: ResultType.error, message: 'too large');
    }
    if (n >= confirmMaterializeBytes && context.mounted) {
      final ok = await _confirmLargeOpen(context, fileName, n);
      if (!ok) {
        return OpenResult(type: ResultType.error, message: 'cancelled');
      }
    }
    final dest = await _tempTarget(fileName);
    if (n >= confirmMaterializeBytes && context.mounted) {
      await _runWithProgress(context, fileName, n, (onProgress) async {
        await _copyFileWithProgress(source, dest, n, onProgress);
      });
    } else {
      await source.copy(dest.path);
    }
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

  /// Materialize a URI to temp (chunked / File.copy), then system open.
  Future<OpenResult> materializeUriAndOpen(
    BuildContext context,
    String uriString,
    String fileName, {
    required int size,
    bool showProgress = false,
  }) async {
    final dest = await _tempTarget(fileName);
    if (showProgress && context.mounted) {
      await _runWithProgress(context, fileName, size, (onProgress) async {
        await StoreUriReader.instance.copyTo(
          uriString,
          dest,
          maxBytes: hardLimitBytes,
          onProgress: onProgress,
        );
      });
    } else {
      await StoreUriReader.instance.copyTo(
        uriString,
        dest,
        maxBytes: hardLimitBytes,
      );
    }
    return _openPath(dest.path);
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

  Future<bool> _confirmLargeOpen(
    BuildContext context,
    String fileName,
    int size,
  ) async {
    final l10n = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.common_confirm),
        content: Text(
          '「$fileName」约 ${formatBytes(size)}。\n'
          '打开前会先复制到临时目录，可能占用时间和存储空间。是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.common_confirm),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _showTooLarge(
    BuildContext context,
    String fileName,
    int size,
  ) async {
    final l10n = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(fileName),
        content: Text(
          '该文件约 ${formatBytes(size)}，超过可在聊天中打开的上限 '
          '（${formatBytes(hardLimitBytes)}）。\n'
          '请到储物袋中查看或导出。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.common_confirm),
          ),
        ],
      ),
    );
  }

  Future<void> _runWithProgress(
    BuildContext context,
    String fileName,
    int total,
    Future<void> Function(void Function(int done, int total) onProgress) work,
  ) async {
    final progress = ValueNotifier<(int, int)>((0, total));
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(fileName),
          content: ValueListenableBuilder<(int, int)>(
            valueListenable: progress,
            builder: (_, value, __) {
              final done = value.$1;
              final tot = value.$2 <= 0 ? 1 : value.$2;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(value: (done / tot).clamp(0.0, 1.0)),
                  const SizedBox(height: 12),
                  Text('${formatBytes(done)} / ${formatBytes(tot)}'),
                ],
              );
            },
          ),
        ),
      ),
    );
    try {
      await work((done, tot) {
        progress.value = (done, tot);
      });
    } finally {
      progress.dispose();
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  static Future<void> _copyFileWithProgress(
    File source,
    File dest,
    int total,
    void Function(int done, int total) onProgress,
  ) async {
    final sink = dest.openWrite();
    var done = 0;
    try {
      await for (final chunk in source.openRead()) {
        sink.add(chunk);
        done += chunk.length;
        onProgress(done, total);
      }
    } finally {
      await sink.close();
    }
  }

  Future<_PreviewKind> _resolvePreviewKind(
    String uriString,
    String storePath,
    String fileName,
  ) async {
    final ext = p.extension(fileName).toLowerCase();
    if (ext.isNotEmpty && !StoreFileVisual.isChatAttachmentPath(storePath)) {
      return _mapPreviewKind(StoreFileVisual.previewKind(storePath));
    }

    final local = await StoreAttachmentRef.fileFromStoreUri(uriString);
    if (local != null) {
      try {
        final head = await local.openRead(0, 16).fold<List<int>>(
              <int>[],
              (prev, chunk) => prev..addAll(chunk),
            );
        return _mapPreviewKind(
          StoreFileVisual.previewKind(storePath, head: head),
        );
      } catch (_) {}
    }

    return _mapPreviewKind(StoreFileVisual.previewKind(storePath));
  }

  static _PreviewKind _mapPreviewKind(StorePreviewKind kind) {
    return switch (kind) {
      StorePreviewKind.image => _PreviewKind.image,
      StorePreviewKind.text => _PreviewKind.text,
      StorePreviewKind.other => _PreviewKind.other,
    };
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

enum _PreviewKind { image, text, other }
