import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../models/channel.dart';
import '../../services/error_handler_service.dart';

/// 长按会话行弹出的底部菜单。
///
/// - 查看会话（仅非当前会话）
/// - 查看 Trace
/// - 分叉（复制当前会话到新会话）
/// - 重置会话（仅当前会话且回调非空）
/// - 复制会话标题和 ID
/// - 复制 Channel ID
///
/// 会等到 bottom sheet 完全关闭后再执行对应回调，因此调用方在回调里再
/// 关抽屉/导航不会与 sheet 的退场动画打架。
Future<void> showSessionRowMenu(
  BuildContext context, {
  required Channel session,
  String? sessionTitle,
  required bool isCurrentSession,
  VoidCallback? onViewSession,
  VoidCallback? onViewTrace,
  VoidCallback? onForkSession,
  VoidCallback? onResetSession,
}) async {
  final l10n = AppLocalizations.of(context);
  final title = (sessionTitle ?? session.name).trim();
  final displayTitle = title.isEmpty ? session.name : title;

  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      Widget item({
        required IconData icon,
        required String label,
        required String value,
      }) {
        return ListTile(
          leading: Icon(icon),
          title: Text(label),
          onTap: () => Navigator.pop(sheetContext, value),
        );
      }

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isCurrentSession && onViewSession != null)
              item(
                icon: Icons.chat_outlined,
                label: l10n.chat_viewSession,
                value: 'viewSession',
              ),
            if (onViewTrace != null)
              item(
                icon: Icons.psychology_outlined,
                label: l10n.chat_viewTrace,
                value: 'viewTrace',
              ),
            if (onForkSession != null)
              item(
                icon: Icons.call_split,
                label: l10n.chat_forkSession,
                value: 'fork',
              ),
            if (isCurrentSession && onResetSession != null)
              item(
                icon: Icons.refresh,
                label: l10n.chat_resetSession,
                value: 'reset',
              ),
            item(
              icon: Icons.copy_all,
              label: l10n.chat_copySessionTitleAndId,
              value: 'copyTitleAndId',
            ),
            item(
              icon: Icons.tag,
              label: l10n.chat_copyChannelId,
              value: 'copyChannelId',
            ),
          ],
        ),
      );
    },
  );
  if (!context.mounted) return;

  switch (action) {
    case 'viewSession':
      onViewSession?.call();
    case 'viewTrace':
      onViewTrace?.call();
    case 'fork':
      onForkSession?.call();
    case 'reset':
      onResetSession?.call();
    case 'copyTitleAndId':
      await _copyText(
        context,
        '$displayTitle\n${session.id}',
      );
    case 'copyChannelId':
      await _copyText(context, session.id);
  }
}

Future<void> _copyText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  showTopToast(
    context,
    AppLocalizations.of(context).chat_copiedToClipboard,
    icon: Icons.check_circle,
    color: Colors.green,
  );
}
