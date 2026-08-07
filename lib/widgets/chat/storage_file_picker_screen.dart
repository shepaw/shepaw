import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../screens/storage_browser_screen.dart';

/// 从本机储物袋 store 浏览并选择文件，供聊天附件等场景使用。
///
/// 排版与 [StorageBrowserScreen]（本机空间文件浏览）一致。
class StorageFilePickerScreen extends StatelessWidget {
  const StorageFilePickerScreen({
    super.key,
    this.maxSelection = 9,
  });

  /// 最多可选文件数（通常为聊天待发送队列剩余容量）。
  final int maxSelection;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return StorageBrowserScreen(
      pickForAttachment: true,
      maxPickCount: maxSelection,
      title: l10n.chat_storageFilePickerTitle,
      readOnly: true,
    );
  }
}
