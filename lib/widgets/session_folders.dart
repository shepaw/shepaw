import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/folded_sessions.dart';
import '../utils/session_utils.dart';

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
///
/// 点一下就地展开这一组的会话（行画在它下面，不开新页面），`expanded` 控制
/// 箭头方向。
class SessionFolderTile extends StatelessWidget {
  const SessionFolderTile({
    super.key,
    required this.summary,
    this.expanded = false,
    this.onTap,
  });

  final SessionFolderSummary summary;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // 主机给的「最近一条」标题可能整段是引擎标签或 [implicit] 提示。
    // 工作流组只留启动时的第一句，和展开后的记录行同一个口径。
    final cleaned = SessionUtils.cleanClaudeSessionTitle(summary.latestTitle);
    final latest = summary.kind == SessionFolderKind.flow
        ? SessionUtils.firstSentenceTitle(cleaned)
        : cleaned;
    return ListTile(
      leading: Icon(sessionFolderIcon(summary.kind)),
      title: Text(AppLocalizations.of(context).folder_tileTitle(
          sessionFolderLabel(AppLocalizations.of(context), summary.kind),
          summary.count)),
      subtitle: latest == null
          ? null
          : Text(latest, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: AnimatedRotation(
        turns: expanded ? 0.25 : 0,
        duration: const Duration(milliseconds: 150),
        child: const Icon(Icons.chevron_right),
      ),
      onTap: onTap,
    );
  }
}
