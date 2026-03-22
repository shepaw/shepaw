import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/message.dart';
import '../../providers/app_state.dart';
import '../../utils/message_utils.dart';
import '../../l10n/app_localizations.dart';

/// Shows a context menu (bottom sheet) for a message.
///
/// Actions: Copy, Reply, Download, Rollback, Re-edit, Delete.
void showMessageContextMenu(
  BuildContext context, {
  required Message message,
  required bool isGroupMode,
  required VoidCallback onReply,
  required VoidCallback onRollback,
  required VoidCallback onReEdit,
  required VoidCallback onDelete,
  VoidCallback? onViewTrace,
}) {
  showModalBottomSheet(
    context: context,
    builder: (context) {
      final menuL10n = AppLocalizations.of(context);
      final userId = Provider.of<AppState>(context, listen: false).currentUser?.id ?? 'user';

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onViewTrace != null)
              ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: Text(menuL10n.chat_viewTrace),
                onTap: () {
                  Navigator.pop(context);
                  onViewTrace();
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(menuL10n.common_copy),
              onTap: () {
                Navigator.pop(context);
                Clipboard.setData(ClipboardData(text: message.content));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(menuL10n.chat_copiedToClipboard)),
                );
              },
            ),
            if (!message.from.isUser || isGroupMode)
              ListTile(
                leading: const Icon(Icons.reply),
                title: Text(menuL10n.common_reply),
                onTap: () {
                  Navigator.pop(context);
                  onReply();
                },
              ),
            if (message.type == MessageType.image || message.type == MessageType.file)
              ListTile(
                leading: const Icon(Icons.download),
                title: Text(menuL10n.chat_download),
                onTap: () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(menuL10n.common_featureComingSoon)),
                  );
                },
              ),
            if (message.from.isUser) ...[
              const Divider(),
              ListTile(
                leading: const Icon(Icons.replay, color: Colors.orange),
                title: Text(menuL10n.chat_rollback, style: const TextStyle(color: Colors.orange)),
                subtitle: Text(menuL10n.chat_rollbackSub),
                onTap: () {
                  Navigator.pop(context);
                  onRollback();
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_note, color: Colors.blue),
                title: Text(menuL10n.chat_reEdit, style: const TextStyle(color: Colors.blue)),
                subtitle: Text(menuL10n.chat_reEditSub),
                onTap: () {
                  Navigator.pop(context);
                  onReEdit();
                },
              ),
            ],
            if (MessageUtils.canDeleteMessage(message, userId))
              const Divider(),
            if (MessageUtils.canDeleteMessage(message, userId))
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: Text(menuL10n.common_delete, style: const TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  onDelete();
                },
              ),
          ],
        ),
      );
    },
  );
}
