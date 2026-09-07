import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/channel.dart';
import '../../services/local_database_service.dart';

/// 会话列表「更多」菜单按钮（编辑 / 全部已读）。
///
/// 由调用方作为 `moreButton` 传入 [SessionListPanel] /
/// [GroupSessionListPanel]，渲染在「新建会话」行右侧；搜索栏只保留输入。
/// 未读数变化后由 [refreshTick] 驱动重新查询。
///
/// 未读总数是 Stateful 缓存的：原先在 `build()` 里现造 Future，父级每次重建
/// （搜索输入、列表刷新）都会重跑一轮查询；且点开菜单前还会再查一遍，直接造成
/// 「点了 ⋯ 要等一下才弹出」。现在只在 sessions 变化或 refreshTick 触发时查一次。
class SessionListHeaderMoreButton extends StatefulWidget {
  final List<Channel> sessions;
  final LocalDatabaseService databaseService;

  /// 全部已读后调用方自增，按钮据此重新查询未读数（与列表刷新共用）。
  final ValueListenable<int> refreshTick;

  final Future<void> Function() onMarkAll;

  /// 进入批量选择（编辑）模式；空则菜单不显示「编辑」项。
  final VoidCallback? onEnterSelectionMode;

  const SessionListHeaderMoreButton({
    super.key,
    required this.sessions,
    required this.databaseService,
    required this.refreshTick,
    required this.onMarkAll,
    this.onEnterSelectionMode,
  });

  @override
  State<SessionListHeaderMoreButton> createState() =>
      _SessionListHeaderMoreButtonState();
}

class _SessionListHeaderMoreButtonState
    extends State<SessionListHeaderMoreButton> {
  Future<int>? _unreadFuture;

  /// 上次查到的总数：刷新期间用它顶替，避免按钮在 0 和 N 之间闪。
  int _lastTotal = 0;

  @override
  void initState() {
    super.initState();
    widget.refreshTick.addListener(_onRefreshTick);
    _unreadFuture = _loadTotalUnread();
  }

  @override
  void didUpdateWidget(covariant SessionListHeaderMoreButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshTick != widget.refreshTick) {
      oldWidget.refreshTick.removeListener(_onRefreshTick);
      widget.refreshTick.addListener(_onRefreshTick);
    }
    // sessions 换了引用就重查；否则沿用上一次的 Future，避免每次 build 重跑。
    if (!identical(oldWidget.sessions, widget.sessions)) {
      _unreadFuture = _loadTotalUnread();
    }
  }

  @override
  void dispose() {
    widget.refreshTick.removeListener(_onRefreshTick);
    super.dispose();
  }

  void _onRefreshTick() {
    if (!mounted) return;
    setState(() => _unreadFuture = _loadTotalUnread());
  }

  /// 一次查询汇总全部会话未读，替代逐会话查询的 N 次串行往返。
  Future<int> _loadTotalUnread() async {
    final counts = await widget.databaseService.getUnreadCountsByChannels(
      widget.sessions.map((s) => s.id).toList(),
    );
    var total = 0;
    for (final count in counts.values) {
      total += count;
    }
    _lastTotal = total;
    return total;
  }

  /// [knownTotal] 用已查到的值，不再在弹菜单前阻塞等待——这是点击卡顿的来源。
  Future<void> _showMenu(BuildContext context, int knownTotal) async {
    final l10n = AppLocalizations.of(context);

    final items = <PopupMenuEntry<String>>[];
    if (widget.onEnterSelectionMode != null && widget.sessions.length > 1) {
      items.add(
        PopupMenuItem<String>(
          value: 'edit',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.edit_outlined, size: 20),
              const SizedBox(width: 12),
              Text(l10n.common_edit),
            ],
          ),
        ),
      );
    }
    if (knownTotal > 0) {
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
      case 'edit':
        widget.onEnterSelectionMode?.call();
      case 'markAll':
        await widget.onMarkAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final hasMenu =
        (widget.onEnterSelectionMode != null && widget.sessions.length > 1);

    return FutureBuilder<int>(
      future: _unreadFuture,
      builder: (context, snapshot) {
        final totalUnread = snapshot.data ?? _lastTotal;
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
              onPressed: () => _showMenu(buttonContext, totalUnread),
            );
          },
        );
      },
    );
  }
}
