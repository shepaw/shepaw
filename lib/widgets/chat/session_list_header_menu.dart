import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/channel.dart';
import '../../services/local_database_service.dart';

/// 会话列表「更多」菜单按钮（全部已读 / Trace / 重置会话 / 批量选择）。
///
/// 由调用方作为 `moreButton` 传入 [SessionListPanel] /
/// [GroupSessionListPanel]，渲染在「新建会话」行右侧；搜索栏只保留输入。
/// 未读数变化后由 [refreshTick] 驱动重新查询。
class SessionListHeaderMoreButton extends StatelessWidget {
  final List<Channel> sessions;
  final LocalDatabaseService databaseService;

  /// 全部已读后调用方自增，按钮据此重新查询未读数（与列表刷新共用）。
  final ValueListenable<int> refreshTick;

  final Future<void> Function() onMarkAll;
  final VoidCallback? onShowTraces;

  /// 重置当前会话（对当前正在查看的会话生效）。
  final VoidCallback? onResetSession;
  final VoidCallback? onEnterSelectionMode;

  const SessionListHeaderMoreButton({
    super.key,
    required this.sessions,
    required this.databaseService,
    required this.refreshTick,
    required this.onMarkAll,
    this.onShowTraces,
    this.onResetSession,
    this.onEnterSelectionMode,
  });

  Future<int> _totalUnread() async {
    var total = 0;
    for (final session in sessions) {
      total += await databaseService.getUnreadCountByChannel(session.id);
    }
    return total;
  }

  Future<void> _showMenu(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final totalUnread = await _totalUnread();
    if (!context.mounted) return;

    final items = <PopupMenuEntry<String>>[];
    if (totalUnread > 0) {
      items.add(
        PopupMenuItem<String>(
          value: 'markAll',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.done_all, size: 20),
              const SizedBox(width: 12),
              Text(l10n.chat_markAllSessionsRead),
            ],
          ),
        ),
      );
    }
    if (onShowTraces != null) {
      items.add(
        PopupMenuItem<String>(
          value: 'traces',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.psychology_outlined, size: 20),
              const SizedBox(width: 12),
              Text(l10n.chat_viewTrace),
            ],
          ),
        ),
      );
    }
    if (onResetSession != null) {
      items.add(
        PopupMenuItem<String>(
          value: 'reset',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.refresh, size: 20),
              const SizedBox(width: 12),
              Text(l10n.chat_resetSession),
            ],
          ),
        ),
      );
    }
    if (onEnterSelectionMode != null && sessions.length > 1) {
      items.add(
        PopupMenuItem<String>(
          value: 'select',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.edit_outlined, size: 20),
              const SizedBox(width: 12),
              Text(l10n.chat_selectSessions),
            ],
          ),
        ),
      );
    }
    if (items.isEmpty) return;

    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final topRight =
        box.localToGlobal(box.size.topRight(Offset.zero), ancestor: overlay);
    final position = RelativeRect.fromLTRB(
      topRight.dx - 200,
      topRight.dy,
      overlay.size.width - topRight.dx,
      overlay.size.height - topRight.dy,
    );

    final action = await showMenu<String>(
      context: context,
      position: position,
      items: items,
    );
    if (!context.mounted || action == null) return;

    switch (action) {
      case 'markAll':
        await onMarkAll();
      case 'traces':
        onShowTraces?.call();
      case 'reset':
        onResetSession?.call();
      case 'select':
        onEnterSelectionMode?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final hasMenu = onShowTraces != null ||
        onResetSession != null ||
        (onEnterSelectionMode != null && sessions.length > 1);

    return ValueListenableBuilder<int>(
      valueListenable: refreshTick,
      builder: (context, tick, _) {
        return FutureBuilder<int>(
          key: ValueKey(tick),
          future: _totalUnread(),
          builder: (context, snapshot) {
            final totalUnread = snapshot.data ?? 0;
            if (!hasMenu && totalUnread <= 0) {
              return const SizedBox.shrink();
            }

            return Builder(
              builder: (buttonContext) {
                return IconButton(
                  icon: const Icon(Icons.more_vert, size: 20),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 36, height: 36),
                  visualDensity: VisualDensity.compact,
                  tooltip: l10n.common_more,
                  onPressed: () => _showMenu(buttonContext),
                );
              },
            );
          },
        );
      },
    );
  }
}
