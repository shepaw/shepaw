import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../models/attachment_data.dart';
import '../storage/store_protocol.dart';
import '../utils/layout_utils.dart';

/// In-app preview for store:// files (image / text).
///
/// - Desktop (left list + chat pane): pushed on the chat [Navigator], fills
///   the entire chat area without covering the left panel.
/// - Mobile: full-screen page.
class StoreFilePreview {
  StoreFilePreview._();

  static Future<void> showImage(
    BuildContext context, {
    required String fileName,
    required Uint8List bytes,
    String? storeUri,
  }) {
    return _push(
      context,
      StoreFilePreviewPage(
        fileName: fileName,
        bytes: bytes,
        storeUri: storeUri,
        body: InteractiveViewer(
          child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
        ),
      ),
    );
  }

  /// Local file preview — avoids holding a second encoded copy in Dart heap.
  static Future<void> showImageFile(
    BuildContext context, {
    required String fileName,
    required File file,
    String? storeUri,
  }) {
    return _push(
      context,
      StoreFilePreviewPage(
        fileName: fileName,
        sourceFile: file,
        storeUri: storeUri,
        body: InteractiveViewer(
          child: Center(child: Image.file(file, fit: BoxFit.contain)),
        ),
      ),
    );
  }

  static Future<void> showText(
    BuildContext context, {
    required String fileName,
    required String text,
    Uint8List? bytes,
    File? sourceFile,
    String? storeUri,
    bool asMarkdown = false,
  }) {
    assert(bytes != null || sourceFile != null);
    final body = asMarkdown
        ? Markdown(
            data: text,
            selectable: true,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          )
        : SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              text,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.35,
              ),
            ),
          );
    return _push(
      context,
      StoreFilePreviewPage(
        fileName: fileName,
        bytes: bytes,
        sourceFile: sourceFile,
        storeUri: storeUri,
        body: body,
      ),
    );
  }

  /// Nearest navigator: desktop chat pane / mobile full screen.
  static Future<void> _push(BuildContext context, Widget page) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => page,
        fullscreenDialog: !LayoutUtils.isDesktopLayout(context),
      ),
    );
  }
}

/// Full-area preview page (chat pane on desktop, screen on mobile).
class StoreFilePreviewPage extends StatelessWidget {
  const StoreFilePreviewPage({
    super.key,
    required this.fileName,
    required this.body,
    this.bytes,
    this.sourceFile,
    this.storeUri,
  });

  final String fileName;
  final Uint8List? bytes;
  final File? sourceFile;
  final String? storeUri;
  final Widget body;

  Future<void> _openExternally() async {
    if (sourceFile != null) {
      final dir = await getTemporaryDirectory();
      final safe = AttachmentData.safeFileName(fileName);
      final dest = File(p.join(dir.path, 'shepaw_store_$safe'));
      await sourceFile!.copy(dest.path);
      await OpenFile.open(dest.path);
      return;
    }
    final data = bytes;
    if (data == null) return;
    final dir = await getTemporaryDirectory();
    final safe = AttachmentData.safeFileName(fileName);
    final file = File(p.join(dir.path, 'shepaw_store_$safe'));
    await file.writeAsBytes(data, flush: true);
    await OpenFile.open(file.path);
  }

  Future<void> _copyPath(BuildContext context) async {
    final uri = storeUri;
    if (uri == null || uri.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: uri));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.storage_browserPathCopied)),
    );
  }

  Future<void> _shareLink(BuildContext context) async {
    final uri = storeUri;
    if (uri == null || uri.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    final md = formatStoreMarkdownLink(fileName, uri);
    if (LayoutUtils.isDesktopLayout(context)) {
      await Clipboard.setData(ClipboardData(text: md));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.storage_browserLinkCopied)),
      );
      return;
    }
    await Share.share(md, subject: fileName);
  }

  @override
  Widget build(BuildContext context) {
    final desktop = LayoutUtils.isDesktopLayout(context);
    final l10n = AppLocalizations.of(context);
    final hasUri = storeUri != null && storeUri!.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
        leading: IconButton(
          tooltip: desktop ? '关闭' : '返回',
          icon: Icon(desktop ? Icons.close : Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          if (hasUri) ...[
            IconButton(
              tooltip: l10n.storage_browserCopyPath,
              icon: const Icon(Icons.link),
              onPressed: () => _copyPath(context),
            ),
            IconButton(
              tooltip: l10n.storage_browserShareLink,
              icon: const Icon(Icons.ios_share_outlined),
              onPressed: () => _shareLink(context),
            ),
          ],
          IconButton(
            tooltip: '用系统应用打开',
            icon: const Icon(Icons.open_in_new),
            onPressed: _openExternally,
          ),
        ],
      ),
      body: SafeArea(child: body),
    );
  }
}
