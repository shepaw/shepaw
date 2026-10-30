import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/folded_sessions.dart';

String sessionFolderLabel(AppLocalizations l10n, SessionFolderKind kind) =>
    switch (kind) {
      SessionFolderKind.group => l10n.folder_group,
      SessionFolderKind.delegated => l10n.folder_delegated,
      SessionFolderKind.flow => l10n.folder_flow,
      SessionFolderKind.ide => l10n.folder_ide,
      SessionFolderKind.terminal => l10n.folder_terminal,
    };

IconData sessionFolderIcon(SessionFolderKind kind) => switch (kind) {
      SessionFolderKind.group => Icons.groups_outlined,
      SessionFolderKind.delegated => Icons.call_made,
      SessionFolderKind.flow => Icons.account_tree_outlined,
      SessionFolderKind.ide => Icons.laptop_mac,
      SessionFolderKind.terminal => Icons.terminal,
    };

/// 会话列表顶部的一行折叠组："群聊 · 6"，副标题是最近一条的标题。
/// 折叠组不计未读，所以没有角标。
class SessionFolderTile extends StatelessWidget {
  const SessionFolderTile({super.key, required this.summary, this.onTap});

  final SessionFolderSummary summary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(sessionFolderIcon(summary.kind)),
      title: Text(AppLocalizations.of(context).folder_tileTitle(
          sessionFolderLabel(AppLocalizations.of(context), summary.kind),
          summary.count)),
      subtitle: summary.latestTitle.isEmpty
          ? null
          : Text(summary.latestTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
