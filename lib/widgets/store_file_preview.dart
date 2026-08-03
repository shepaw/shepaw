import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/attachment_data.dart';

/// Simple in-app preview sheets for store:// files (image / text).
class StoreFilePreview {
  StoreFilePreview._();

  static Future<void> showImage(
    BuildContext context, {
    required String fileName,
    required Uint8List bytes,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _PreviewScaffold(
        fileName: fileName,
        bytes: bytes,
        body: InteractiveViewer(
          child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
        ),
      ),
    );
  }

  static Future<void> showText(
    BuildContext context, {
    required String fileName,
    required String text,
    required Uint8List bytes,
    bool asMarkdown = false,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) {
        final body = asMarkdown
            ? Markdown(data: text, selectable: true)
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
        return _PreviewScaffold(
          fileName: fileName,
          bytes: bytes,
          body: body,
        );
      },
    );
  }
}

class _PreviewScaffold extends StatelessWidget {
  const _PreviewScaffold({
    required this.fileName,
    required this.bytes,
    required this.body,
  });

  final String fileName;
  final Uint8List bytes;
  final Widget body;

  Future<void> _openExternally() async {
    final dir = await getTemporaryDirectory();
    final safe = AttachmentData.safeFileName(fileName);
    final file = File(p.join(dir.path, 'shepaw_store_$safe'));
    await file.writeAsBytes(bytes, flush: true);
    await OpenFile.open(file.path);
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.85;
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Open with system app',
                  icon: const Icon(Icons.open_in_new),
                  onPressed: _openExternally,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: body),
        ],
      ),
    );
  }
}
