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
    return ListTile(
      leading: Icon(sessionFolderIcon(summary.kind)),
      title: Text(AppLocalizations.of(context).folder_tileTitle(
          sessionFolderLabel(AppLocalizations.of(context), summary.kind),
          summary.count)),
      subtitle: summary.latestTitle.isEmpty
          ? null
          : Text(summary.latestTitle,
              maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: AnimatedRotation(
        turns: expanded ? 0.25 : 0,
        duration: const Duration(milliseconds: 150),
        child: const Icon(Icons.chevron_right),
      ),
      onTap: onTap,
    );
  }
}

/// 展开某一组时钉在列表顶部的那一行：滑多远都在，点一下就收起这一组。
///
/// 组里会话多的时候，收起原本得滑回最顶部才够得着那一行折叠组。
class SessionFolderStickyHeader extends StatelessWidget {
  const SessionFolderStickyHeader({
    super.key,
    required this.summary,
    required this.onTap,
  });

  /// 当前展开的那一组。
  final SessionFolderSummary summary;

  /// 收起这一组。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _SessionFolderTileHeaderDelegate(
        summary: summary,
        onTap: onTap,
      ),
    );
  }
}

class _SessionFolderTileHeaderDelegate extends SliverPersistentHeaderDelegate {
  _SessionFolderTileHeaderDelegate({
    required this.summary,
    required this.onTap,
  });

  final SessionFolderSummary summary;
  final VoidCallback onTap;

  /// 行高跟着有没有副标题走，与 [ListTile] 的规格一致（单行 56、双行 72）。
  double get _extent => summary.latestTitle.isEmpty ? 56 : 72;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    return DecoratedBox(
      // 钉住时底下有内容滚过，得垫一个不透明的底。
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(bottom: BorderSide(color: theme.dividerColor, width: 1)),
      ),
      child: SessionFolderTile(summary: summary, expanded: true, onTap: onTap),
    );
  }

  @override
  double get maxExtent => _extent;

  @override
  double get minExtent => _extent;

  @override
  bool shouldRebuild(covariant _SessionFolderTileHeaderDelegate oldDelegate) =>
      oldDelegate.summary != summary ||
      oldDelegate.onTap != onTap ||
      oldDelegate._extent != _extent;
}
