import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../controllers/chat_controller.dart';
import '../../models/channel.dart';
import '../../services/local_database_service.dart';
import '../../utils/layout_utils.dart';
import '../../utils/session_utils.dart';
import '../../l10n/app_localizations.dart';
import 'session_unread_badge.dart';
import 'session_list_header_menu.dart';
import 'session_preview_entry.dart';
import 'session_row_menu.dart';
import 'chat_panel_scope.dart';

/// Session list panel for DM (1-on-1) chat sessions.
///
/// Shows all sessions for a given agent, supports:
/// - Creating new sessions
/// - Switching between sessions
/// - Batch selection & deletion
///
/// 标题栏已并入抽屉搜索栏，本组件只负责列表本身与批量选择 UI。
/// 「更多」按钮（[SessionListHeaderMoreButton]）由调用方传入，渲染在
/// 「新建会话」行右侧。
class SessionListPanel extends StatelessWidget {
  final List<Channel> sessions;
  final String? currentChannelId;
  final ChatController controller;
  final VoidCallback onNewSession;
  final ValueChanged<String> onSwitchSession;
  final ValueChanged<List<String>> onBatchDelete;
  final String? agentName;
  final String? agentAvatar;
  final String? agentId;

  /// 外部驱动的列表刷新（全部已读后自增，未读角标与预览随之刷新）。
  final ValueListenable<int> listRefreshTick;

  /// 外部驱动的批量选择进入（「更多」菜单点编辑后自增）。
  final ValueListenable<int> selectionModeRequest;

  /// 会话列表「更多」按钮（[SessionListHeaderMoreButton]），渲染在
  /// 「新建会话」行右侧；为空则整行保持纯新建入口。
  final Widget? moreButton;

  /// 每会话底部菜单「查看 Trace」回调（按该会话过滤）。
  final void Function(String channelId, String channelName)? onViewTrace;

  /// 每会话底部菜单「分叉」回调。
  final void Function(Channel session)? onForkSession;

  /// 每会话底部菜单「复制到」回调（复制到另一个 agent 的新会话）。
  final void Function(Channel session)? onCopyToAgent;

  /// 每会话底部菜单「重置会话」回调（仅当前会话行显示）。
  final VoidCallback? onResetSession;

  /// 跨抽屉开关存活的行预览缓存。由 [ChatScreen] 持有；为空则组件自建。
  final Map<String, SessionPreviewEntry>? previewCache;

  const SessionListPanel({
    super.key,
    required this.sessions,
    this.currentChannelId,
    required this.controller,
    required this.onNewSession,
    required this.onSwitchSession,
    required this.onBatchDelete,
    this.agentName,
    this.agentAvatar,
    this.agentId,
    required this.listRefreshTick,
    required this.selectionModeRequest,
    this.moreButton,
    this.onViewTrace,
    this.onForkSession,
    this.onCopyToAgent,
    this.onResetSession,
    this.previewCache,
  });

  @override
  Widget build(BuildContext context) {
    return _SessionListContent(
      sessions: sessions,
      currentChannelId: currentChannelId,
      controller: controller,
      onNewSession: onNewSession,
      onSwitchSession: onSwitchSession,
      onBatchDelete: onBatchDelete,
      listRefreshTick: listRefreshTick,
      selectionModeRequest: selectionModeRequest,
      moreButton: moreButton,
      onViewTrace: onViewTrace,
      onForkSession: onForkSession,
      onCopyToAgent: onCopyToAgent,
      onResetSession: onResetSession,
      previewCache: previewCache,
    );
  }
}

class _SessionListContent extends StatefulWidget {
  final List<Channel> sessions;
  final String? currentChannelId;

  /// 用于读取 [ChatService.typingChannelIds] 以显示会话的「输入中」状态。
  final ChatController controller;

  final VoidCallback onNewSession;
  final ValueChanged<String> onSwitchSession;
  final ValueChanged<List<String>> onBatchDelete;
  final ValueListenable<int> listRefreshTick;
  final ValueListenable<int> selectionModeRequest;

  /// 会话列表「更多」按钮，渲染在「新建会话」行右侧。
  final Widget? moreButton;

  /// 每会话底部菜单「查看 Trace」回调（按该会话过滤）。
  final void Function(String channelId, String channelName)? onViewTrace;

  /// 每会话底部菜单「分叉」回调。
  final void Function(Channel session)? onForkSession;

  /// 每会话底部菜单「复制到」回调（复制到另一个 agent 的新会话）。
  final void Function(Channel session)? onCopyToAgent;

  /// 每会话底部菜单「重置会话」回调（仅当前会话行显示）。
  final VoidCallback? onResetSession;

  /// 跨抽屉开关存活的行预览缓存；为空则 [State] 自建一份。
  final Map<String, SessionPreviewEntry>? previewCache;

  const _SessionListContent({
    required this.sessions,
    this.currentChannelId,
    required this.controller,
    required this.onNewSession,
    required this.onSwitchSession,
    required this.onBatchDelete,
    required this.listRefreshTick,
    required this.selectionModeRequest,
    this.moreButton,
    this.onViewTrace,
    this.onForkSession,
    this.onCopyToAgent,
    this.onResetSession,
    this.previewCache,
  });

  @override
  State<_SessionListContent> createState() => _SessionListContentState();
}

class _SessionListContentState extends State<_SessionListContent> {
  bool _isSelectionMode = false;
  Set<String> _selectedIds = {};
  final _databaseService = LocalDatabaseService();

  /// 组件自建的回退缓存（未传入 [previewCache] 时使用，例如测试）。
  final Map<String, SessionPreviewEntry> _localPreviews = {};

  /// 行级预览缓存（channelId → 最近一次查询结果）。
  ///
  /// 优先用调用方传入的 [previewCache]（跨抽屉路由存活）；否则用本地 map。
  /// 渲染永远读缓存（无 FutureBuilder 空态），数据过期时后台重查。
  Map<String, SessionPreviewEntry> get _previews =>
      widget.previewCache ?? _localPreviews;

  @override
  void initState() {
    super.initState();
    widget.listRefreshTick.addListener(_onExternalListRefresh);
    widget.selectionModeRequest.addListener(_onSelectionModeRequested);
    // 复用跨路由缓存时先标过期：首帧仍画旧标题/预览，后台补新鲜度。
    if (widget.previewCache != null) {
      _markAllStale();
    }
    _refreshStalePreviews();
  }

  /// 批量补齐所有过期行的预览：3 次查询替代每会话 3 次的 N×3 串行往返
  /// （50 个会话原本是 150 次 sqflite 往返）。
  Future<void> _refreshStalePreviews() async {
    final ids = widget.sessions
        .map((s) => s.id)
        .where((id) {
          final e = _previews[id];
          return e == null || (e.stale && !e.refreshing);
        })
        .toList();
    if (ids.isEmpty) return;

    // 先标记为刷新中，避免逐行再各发起一次查询。
    for (final id in ids) {
      _previews.putIfAbsent(id, SessionPreviewEntry.new)
        ..stale = false
        ..refreshing = true;
    }

    try {
      final firsts = await _databaseService.getFirstMessagesByChannels(ids);
      final latests = await _databaseService.getLatestMessagesByChannels(ids);
      final unreads = await _databaseService.getUnreadCountsByChannels(ids);
      if (!mounted) return;
      for (final id in ids) {
        final e = _previews[id];
        if (e == null) continue;
        e.data = (firsts[id], latests[id], unreads[id] ?? 0, null);
        e.refreshing = false;
      }
      setState(() {});
    } catch (_) {
      if (!mounted) return;
      for (final id in ids) {
        _previews[id]?.refreshing = false;
      }
    }
  }

  @override
  void didUpdateWidget(_SessionListContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.listRefreshTick != oldWidget.listRefreshTick) {
      oldWidget.listRefreshTick.removeListener(_onExternalListRefresh);
      widget.listRefreshTick.addListener(_onExternalListRefresh);
    }
    if (widget.currentChannelId != oldWidget.currentChannelId) {
      _markAllStale();
    }
    // 会话被删后缓存条目随手清理
    _previews
        .removeWhere((k, _) => !widget.sessions.any((s) => s.id == k));
    // 新增/过期的会话用批量查询补齐（无待补项时直接返回）。
    _refreshStalePreviews();
  }

  @override
  void dispose() {
    widget.listRefreshTick.removeListener(_onExternalListRefresh);
    widget.selectionModeRequest.removeListener(_onSelectionModeRequested);
    super.dispose();
  }

  void _onSelectionModeRequested() {
    if (!mounted) return;
    setState(() {
      _isSelectionMode = true;
      _selectedIds.clear();
    });
  }

  /// 外部全量刷新（全部已读后 tick 自增）：全部行标记过期，重建时后台重查。
  void _onExternalListRefresh() {
    if (!mounted) return;
    _markAllStale();
    setState(() {});
    _refreshStalePreviews();
  }

  void _markAllStale() {
    for (final e in _previews.values) {
      e.stale = true;
    }
  }

  /// 取该行的预览条目；无缓存或已过期则发起后台重查（完成后原地更新）。
  SessionPreviewEntry _entryFor(String channelId) {
    final entry = _previews.putIfAbsent(channelId, SessionPreviewEntry.new);
    if (entry.stale && !entry.refreshing) {
      entry
        ..stale = false
        ..refreshing = true;
      _querySessionPreview(channelId).then((data) {
        entry
          ..data = (data.$1, data.$2, data.$3, null)
          ..refreshing = false;
        if (mounted) setState(() {});
      }).catchError((_) {
        entry.refreshing = false;
      });
    }
    return entry;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Column(
      children: [
        if (_isSelectionMode) _buildSelectionHeader(l10n),
        Expanded(child: _buildList(l10n)),
        if (_isSelectionMode) _buildBottomBar(l10n),
      ],
    );
  }

  Widget _buildSelectionHeader(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _isSelectionMode = false;
                  _selectedIds.clear();
                }),
              ),
              Text(
                l10n.chat_selectSessions,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  _selectedIds = widget.sessions
                      .where((s) => s.id != widget.currentChannelId)
                      .map((s) => s.id)
                      .toSet();
                }),
                child: Text(l10n.osTool_selectAll),
              ),
              TextButton(
                onPressed: () => setState(() {
                  final newSet = <String>{};
                  for (final s in widget.sessions) {
                    if (s.id == widget.currentChannelId) continue;
                    if (!_selectedIds.contains(s.id)) {
                      newSet.add(s.id);
                    }
                  }
                  _selectedIds = newSet;
                }),
                child: Text(l10n.chat_invertSelection),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.chat_selectedCount(_selectedIds.length),
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(AppLocalizations l10n) {
    return ListView.builder(
      key: const PageStorageKey<String>('dm-session-list'),
      itemCount: widget.sessions.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          if (_isSelectionMode) return const SizedBox.shrink();
          return _buildNewSessionItem(context, l10n);
        }
        final session = widget.sessions[index - 1];
        final isCurrent = session.id == widget.currentChannelId;
        final preview = _entryFor(session.id).data;
        final firstMessage = preview?.$1;
        final latestMessage = preview?.$2;
        // 当前会话渲染时未读归零（缓存存原始未读数）。
        final unreadCount = isCurrent ? 0 : preview?.$3 ?? 0;
        return _buildSessionTile(
          context,
          session,
          isCurrent,
          firstMessage,
          latestMessage,
          unreadCount: unreadCount,
          selectionMode: _isSelectionMode,
          selected: _selectedIds.contains(session.id),
          selectionEnabled: !isCurrent,
          onSelectionToggle: isCurrent
              ? null
              : () => setState(() {
                    if (_selectedIds.contains(session.id)) {
                      _selectedIds.remove(session.id);
                    } else {
                      _selectedIds.add(session.id);
                    }
                  }),
        );
      },
    );
  }

  Widget _buildNewSessionItem(BuildContext context, AppLocalizations l10n) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Theme.of(context).primaryColor.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.add,
          color: Theme.of(context).primaryColor,
          size: 24,
        ),
      ),
      title: Text(
        l10n.chat_newSession,
        style: TextStyle(
          color: Theme.of(context).primaryColor,
          fontWeight: FontWeight.w500,
        ),
      ),
      // 「更多」按钮放新建会话行的右侧：搜索栏只留输入，按钮与「新建会话」
      // 同属列表一级操作，视觉上成组。
      trailing: widget.moreButton,
      onTap: () {
        closePanelRoute(context);
        widget.onNewSession();
      },
    );
  }

  Future<(Map<String, dynamic>?, Map<String, dynamic>?, int)>
      _querySessionPreview(String channelId) async {
    final firstMessage =
        await _databaseService.getFirstChannelMessage(channelId);
    final latestMessage =
        await _databaseService.getLatestChannelMessage(channelId);
    final unreadCount =
        await _databaseService.getUnreadCountByChannel(channelId);
    return (firstMessage, latestMessage, unreadCount);
  }

  Widget _buildSessionTile(
    BuildContext context,
    Channel session,
    bool isCurrentSession,
    Map<String, dynamic>? firstMessage,
    Map<String, dynamic>? latestMessage, {
    int unreadCount = 0,
    bool selectionMode = false,
    bool selected = false,
    bool selectionEnabled = true,
    VoidCallback? onSelectionToggle,
  }) {
    final isGroupBound = session.isGroupBoundMemberSession;
    final isSheBound = session.isSheBoundSession;
    final isBound = isGroupBound || isSheBound;
    // 第一行 = 会话第一条消息的第一句（会话标题就是第一句话，不再用
    // 各会话雷同的固定名称占位）；没有消息时退回名称。远端同步的 Claude
    // 会话首条消息可能是本地命令注入的伪消息，跳过并清洗残留标签。
    final rawFirst = firstMessage?['content'] as String?;
    final firstContent = (rawFirst != null &&
            rawFirst.trim().isNotEmpty &&
            !SessionUtils.isClaudeCommandArtifact(rawFirst))
        ? rawFirst
        : null;
    final firstTitle = firstContent == null
        ? null
        : SessionUtils.splitFirstSentence(firstContent).first;
    final titleText =
        SessionUtils.cleanClaudeSessionTitle(firstTitle ?? session.name) ??
            'Session';
    // 第二行 = 首条消息的剩余部分；首句即整条（无剩余）时回落到最新消息。
    final firstRest = firstContent == null
        ? ''
        : SessionUtils.splitFirstSentence(firstContent).rest;
    final latestContent = latestMessage?['content'] as String? ?? '';
    final isSameMessage = firstMessage != null &&
        latestMessage != null &&
        firstMessage['id'] == latestMessage['id'];
    // 没有首条真实消息（如 gmd 成员会话只有创建时的系统说明）时，最新
    // 消息同样可能是系统消息：不拿它做预览，回落到下方的 fallbackPreview。
    final preview = firstRest.isNotEmpty
        ? firstRest
        : (firstMessage == null || isSameMessage ? '' : latestContent);
    // 无消息时的兜底：绑定会话优先显示描述，其余显示占位文案（与旧行为一致）。
    final boundDesc = isBound ? (session.description ?? '').trim() : '';
    final fallbackPreview = boundDesc.isNotEmpty
        ? boundDesc
        : (isGroupBound ? 'Group-bound session' : 'No messages');
    final createdAtStr = latestMessage?['created_at'] as String?;
    String timeText = '';
    if (createdAtStr != null) {
      try {
        final dt = DateTime.parse(createdAtStr);
        final now = DateTime.now();
        if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
          timeText =
              '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
        } else {
          timeText = '${dt.month}/${dt.day}';
        }
      } catch (_) {}
    }

    // 当前会话：图标变橘、头像底色淡橘（与 She 样式同款），整行淡橘背景，
    // 不再需要 Current 文字徽标。
    final avatar = Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isCurrentSession || isSheBound
                ? Colors.orange.withOpacity(0.15)
                : isGroupBound
                    ? Colors.teal.withOpacity(0.15)
                    : Colors.grey[300],
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(
            isSheBound
                ? Icons.pets_outlined
                : isGroupBound
                    ? Icons.groups_outlined
                    : Icons.chat_bubble_outline,
            color: isCurrentSession || isSheBound
                ? Colors.orange[700]
                : isGroupBound
                    ? Colors.teal[700]
                    : Colors.grey[600],
            size: 20,
          ),
        ),
        if (unreadCount > 0) AvatarUnreadBadgeOverlay(count: unreadCount),
      ],
    );

    // 每会话底部菜单回调（查看会话仅非当前会话；重置仅当前会话）。
    final viewSession =
        isCurrentSession ? null : () => widget.onSwitchSession(session.id);
    final viewTrace = widget.onViewTrace == null
        ? null
        : () => widget.onViewTrace!(session.id, session.name);
    final forkSession = widget.onForkSession == null
        ? null
        : () => widget.onForkSession!(session);
    final copyToAgent = widget.onCopyToAgent == null
        ? null
        : () => widget.onCopyToAgent!(session);
    final resetSession = isCurrentSession ? widget.onResetSession : null;
    final isDesktop = LayoutUtils.isDesktopLayout(context);

    return SessionRowHoverHost(
      enabled: isDesktop && !selectionMode,
      builder: (context, hover) {
        return ListTile(
      tileColor: isCurrentSession ? Colors.orange.withOpacity(0.08) : null,
      contentPadding: selectionMode
          ? const EdgeInsets.fromLTRB(8, 0, 16, 0)
          : const EdgeInsets.symmetric(horizontal: 16),
      horizontalTitleGap: selectionMode ? 8 : 16,
      leading: selectionMode
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: selected,
                  onChanged: selectionEnabled
                      ? (_) => onSelectionToggle?.call()
                      : null,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),
                avatar,
              ],
            )
          : avatar,
      title: Row(
        children: [
          Expanded(
            child: Text(
              titleText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // 标题就是会话的第一句话，与第二行同字号，不再按「标题」加重。
              style: const TextStyle(fontSize: 14),
            ),
          ),
          if (isGroupBound)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.teal.withOpacity(0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Group',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.teal[700],
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (isSheBound)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'She',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.orange[700],
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
      // 活跃会话（agent 正在该会话处理任务）显示「输入中」，样式与主页
      // 对话列表一致；监听 typingChannelIds 实时更新，不触发整条重查库。
      subtitle: ValueListenableBuilder<Set<String>>(
        valueListenable: widget.controller.chatService.typingChannelIds,
        builder: (context, typingChannelIds, _) {
          final isTyping = typingChannelIds.contains(session.id);
          if (isTyping) {
            return Text(
              AppLocalizations.of(context).home_typing,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: Colors.green[600],
                fontStyle: FontStyle.italic,
              ),
            );
          }
          return Text(
            preview.isNotEmpty ? preview : fallbackPreview,
            // 两行同尺寸：第二行给到两行高度，多显示一些内容。
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[600],
            ),
          );
        },
      ),
      trailing: sessionRowTrailing(
        context: context,
        showMore: hover.showMore,
        timeText: timeText,
        onMorePressed: hover.showMore
            ? (buttonContext) => hover.holdWhileOpen(
                  () => showSessionRowPopupMenu(
                    context,
                    buttonContext: buttonContext,
                    session: session,
                    sessionTitle: titleText,
                    isCurrentSession: isCurrentSession,
                    onViewSession: viewSession,
                    onViewTrace: viewTrace,
                    onForkSession: forkSession,
                    onCopyToAgent: copyToAgent,
                    onResetSession: resetSession,
                  ),
                )
            : null,
      ),
      onTap: selectionMode
          ? (selectionEnabled ? onSelectionToggle : null)
          : isCurrentSession
              ? () => closePanelRoute(context)
              : () {
                  closePanelRoute(context);
                  widget.onSwitchSession(session.id);
                },
      onLongPress: selectionMode || isDesktop
          ? null
          : () => showSessionRowMenu(
                context,
                session: session,
                sessionTitle: titleText,
                isCurrentSession: isCurrentSession,
                onViewSession: viewSession,
                onViewTrace: viewTrace,
                onForkSession: forkSession,
                onCopyToAgent: copyToAgent,
                onResetSession: resetSession,
              ),
        );
      },
    );
  }

  Widget _buildBottomBar(AppLocalizations l10n) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.delete_outline),
            label: Text(l10n.chat_deleteSelected(_selectedIds.length)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: _selectedIds.isEmpty
                ? null
                : () {
                    closePanelRoute(context);
                    widget.onBatchDelete(_selectedIds.toList());
                  },
          ),
        ),
      ),
    );
  }
}

