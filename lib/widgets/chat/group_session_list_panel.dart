import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../controllers/chat_controller.dart';
import '../../models/channel.dart';
import '../../services/local_database_service.dart';
import '../../storage/group_workspace_service.dart';
import '../../utils/session_utils.dart';
import '../../l10n/app_localizations.dart';
import 'session_unread_badge.dart';
import 'session_list_header_menu.dart';

/// Session list panel for group chat sessions.
///
/// Shows all sessions for a group (parent + children), supports:
/// - Creating new group sessions
/// - Switching between sessions
/// - Batch selection & deletion
///
/// 标题栏已并入抽屉搜索栏，本组件只负责列表本身与批量选择 UI。
/// 「更多」按钮（[SessionListHeaderMoreButton]）由调用方传入，渲染在
/// 「新建会话」行右侧。
class GroupSessionListPanel extends StatelessWidget {
  final List<Channel> sessions;
  final String? currentChannelId;
  final ChatController controller;
  final VoidCallback onNewSession;
  final ValueChanged<String> onSwitchSession;
  final ValueChanged<List<String>> onBatchDelete;

  /// 外部驱动的列表刷新（全部已读后自增，未读角标与预览随之刷新）。
  final ValueListenable<int> listRefreshTick;

  /// 外部驱动的批量选择进入（「更多」菜单点批量选择后自增）。
  final ValueListenable<int> selectionModeRequest;

  /// 会话列表「更多」按钮（[SessionListHeaderMoreButton]），渲染在
  /// 「新建会话」行右侧；为空则整行保持纯新建入口。
  final Widget? moreButton;

  const GroupSessionListPanel({
    super.key,
    required this.sessions,
    this.currentChannelId,
    required this.controller,
    required this.onNewSession,
    required this.onSwitchSession,
    required this.onBatchDelete,
    required this.listRefreshTick,
    required this.selectionModeRequest,
    this.moreButton,
  });

  @override
  Widget build(BuildContext context) {
    return _GroupSessionListContent(
      sessions: sessions,
      currentChannelId: currentChannelId,
      groupChannel: controller.groupChannel,
      controller: controller,
      onNewSession: onNewSession,
      onSwitchSession: onSwitchSession,
      onBatchDelete: onBatchDelete,
      listRefreshTick: listRefreshTick,
      selectionModeRequest: selectionModeRequest,
      moreButton: moreButton,
    );
  }
}

class _GroupSessionListContent extends StatefulWidget {
  final List<Channel> sessions;
  final String? currentChannelId;
  final Channel? groupChannel;

  /// 用于读取 [ChatService.typingChannelIds] 以显示会话的「输入中」状态。
  final ChatController controller;

  final VoidCallback onNewSession;
  final ValueChanged<String> onSwitchSession;
  final ValueChanged<List<String>> onBatchDelete;
  final ValueListenable<int> listRefreshTick;
  final ValueListenable<int> selectionModeRequest;

  /// 会话列表「更多」按钮，渲染在「新建会话」行右侧。
  final Widget? moreButton;

  const _GroupSessionListContent({
    required this.sessions,
    this.currentChannelId,
    this.groupChannel,
    required this.controller,
    required this.onNewSession,
    required this.onSwitchSession,
    required this.onBatchDelete,
    required this.listRefreshTick,
    required this.selectionModeRequest,
    this.moreButton,
  });

  @override
  State<_GroupSessionListContent> createState() =>
      _GroupSessionListContentState();
}

class _GroupSessionListContentState extends State<_GroupSessionListContent> {
  bool _isSelectionMode = false;
  Set<String> _selectedIds = {};
  final _databaseService = LocalDatabaseService();

  @override
  void initState() {
    super.initState();
    widget.selectionModeRequest.addListener(_onSelectionModeRequested);
  }

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Column(
      children: [
        if (_isSelectionMode) _buildSelectionHeader(l10n),
        Expanded(
          child: ValueListenableBuilder<int>(
            valueListenable: widget.listRefreshTick,
            builder: (context, tick, _) => _buildList(l10n, tick),
          ),
        ),
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
                      .where((s) =>
                          s.id != widget.currentChannelId &&
                          s.parentGroupId != null)
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
                    if (s.parentGroupId == null) continue; // skip parent group
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

  Widget _buildList(AppLocalizations l10n, int listRefreshTick) {
    return ListView.builder(
      itemCount: widget.sessions.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          if (_isSelectionMode) return const SizedBox.shrink();
          return _buildNewSessionItem(context, l10n);
        }
        final session = widget.sessions[index - 1];
        final isCurrent = session.id == widget.currentChannelId;
        final isParent = session.parentGroupId == null;
        final isDisabled = isCurrent || isParent;
        return FutureBuilder<
            (Map<String, dynamic>?, Map<String, dynamic>?, int,
                Map<String, dynamic>?)>(
          key: ValueKey('${session.id}_$listRefreshTick'),
          future: _loadSessionPreview(session.id, isCurrent, session),
          builder: (context, snapshot) {
            final firstMessage = snapshot.data?.$1;
            final latestMessage = snapshot.data?.$2;
            final unreadCount = snapshot.data?.$3 ?? 0;
            final orchestration = snapshot.data?.$4;
            final tile = _buildGroupSessionTile(
              context,
              session,
              isCurrent,
              firstMessage,
              latestMessage,
              unreadCount: unreadCount,
              orchestration: orchestration,
              selectionMode: _isSelectionMode,
              selected: _selectedIds.contains(session.id),
              selectionEnabled: !isDisabled,
              onSelectionToggle: isDisabled
                  ? null
                  : () => setState(() {
                        if (_selectedIds.contains(session.id)) {
                          _selectedIds.remove(session.id);
                        } else {
                          _selectedIds.add(session.id);
                        }
                      }),
            );
            return tile;
          },
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
        Navigator.pop(context);
        widget.onNewSession();
      },
    );
  }

  /// 任务编排状态详情面板：最新 round 的 dispatch 决定 / 成员结果 /
  /// 管理员总结（shared/orchestration 轮次快照可视化）。
  void _showOrchestrationSheet(
    BuildContext context,
    Channel session,
    Map<String, dynamic> orchestration,
  ) {
    final round = orchestration['round'] as int? ?? 0;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return FutureBuilder<Map<String, dynamic>?>(
          future: GroupWorkspaceService.instance.readRoundSummary(
            groupId: session.groupFamilyId,
            sessionId: session.id,
            round: round,
          ),
          builder: (context, snapshot) {
            final summary = snapshot.data ?? orchestration;
            return _buildOrchestrationSheetBody(context, summary, round);
          },
        );
      },
    );
  }

  Widget _buildOrchestrationSheetBody(
    BuildContext context,
    Map<String, dynamic> summary,
    int round,
  ) {
    final status = summary['status'] as String? ?? '';
    final steps =
        (summary['dispatch'] as Map<String, dynamic>?)?['steps'] as List? ??
            const [];
    final memberResults =
        summary['member_results'] as Map<String, dynamic>? ?? const {};
    final adminSummary = summary['admin_summary'] as String? ?? '';
    final statusLabel = switch (status) {
      'finished' => '✅ 已完成',
      'members_done' => '🔄 成员回复完成，等待汇总',
      'round_complete' => '🔄 轮次完成',
      'dispatched' => '🔄 已派发',
      _ => '🔄 编排进行中',
    };

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('任务编排状态 · 第 $round 轮',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(statusLabel,
                style: TextStyle(
                    fontSize: 13, color: Colors.orange[800])),
            if (steps.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('本轮派发',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[700])),
              const SizedBox(height: 4),
              for (final s in steps.cast<Map<String, dynamic>>())
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '步骤${s['step']} → ${(s['agents'] as List).join('、')}'
                    '${(s['task'] as String? ?? '').isNotEmpty ? '：${s['task']}' : ''}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
            ],
            if (memberResults.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('成员结果',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[700])),
              const SizedBox(height: 4),
              for (final e in memberResults.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '${e.key}：${_truncate(e.value?['content'] as String? ?? '')}',
                    style: const TextStyle(fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            if (adminSummary.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('管理员总结',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[700])),
              const SizedBox(height: 4),
              Text(adminSummary,
                  style: const TextStyle(fontSize: 13),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis),
            ],
            if (steps.isEmpty &&
                memberResults.isEmpty &&
                adminSummary.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('暂无该轮编排快照',
                    style: TextStyle(fontSize: 13, color: Colors.grey[500])),
              ),
          ],
        ),
      ),
    );
  }

  static String _truncate(String s, [int max = 60]) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  Future<(Map<String, dynamic>?, Map<String, dynamic>?, int,
          Map<String, dynamic>?)>
      _loadSessionPreview(
          String channelId, bool isCurrent, Channel session) async {
    final firstMessage =
        await _databaseService.getFirstChannelMessage(channelId);
    final latestMessage =
        await _databaseService.getLatestChannelMessage(channelId);
    var unreadCount = await _databaseService.getUnreadCountByChannel(channelId);
    if (isCurrent) unreadCount = 0;
    // 任务编排状态（latest.json；不存在 = 从未编排，返回 null）。
    Map<String, dynamic>? orchestration;
    try {
      orchestration =
          await GroupWorkspaceService.instance.readLatestOrchestration(
        groupId: session.groupFamilyId,
        sessionId: channelId,
      );
    } catch (_) {
      orchestration = null;
    }
    return (firstMessage, latestMessage, unreadCount, orchestration);
  }

  Widget _buildGroupSessionTile(
    BuildContext context,
    Channel session,
    bool isCurrentSession,
    Map<String, dynamic>? firstMessage,
    Map<String, dynamic>? latestMessage, {
    int unreadCount = 0,
    Map<String, dynamic>? orchestration,
    bool selectionMode = false,
    bool selected = false,
    bool selectionEnabled = true,
    VoidCallback? onSelectionToggle,
  }) {
    final isParent = session.parentGroupId == null;
    final label = isParent
        ? '#default'
        : SessionUtils.shortSessionId(session.id,
            groupChannel: widget.groupChannel);

    // 任务编排状态角标：latest.json 非终态（running/dispatched/members_done/
    // round_complete）显示「第 N 轮 🔄」；finished 安静（消息日志即结论）。
    final orchestrationStatus = orchestration?['status'] as String? ?? '';
    final isOrchestrating =
        orchestrationStatus.isNotEmpty && orchestrationStatus != 'finished';
    final orchestrationRound = orchestration?['round'] as int? ?? 0;

    // 第一行 = 会话第一条消息的第一句（会话标题就是第一句话），没有消息时
    // 退回「群名 (#id)」；会话编号 #label 仍以小徽标跟在后面。
    final firstContent = firstMessage?['content'] as String?;
    final titleText = firstContent != null && firstContent.trim().isNotEmpty
        ? SessionUtils.splitFirstSentence(firstContent).first
        : '${session.name} ($label)';
    // 第二行 = 首条消息的剩余部分；首句即整条（无剩余）时回落到最新消息。
    final firstRest = firstContent == null
        ? ''
        : SessionUtils.splitFirstSentence(firstContent).rest;
    final latestContent = latestMessage?['content'] as String? ?? '';
    final isSameMessage = firstMessage != null &&
        latestMessage != null &&
        firstMessage['id'] == latestMessage['id'];
    // 没有首条真实消息时，最新消息可能是系统消息：不拿它做预览，
    // 回落到下方的 fallbackPreview。
    final preview = firstRest.isNotEmpty
        ? firstRest
        : (firstMessage == null || isSameMessage ? '' : latestContent);
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

    // 当前会话：图标变橘、头像底色淡橘，整行淡橘背景，不再需要 Current 徽标。
    final avatar = Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isCurrentSession
                ? Colors.orange.withOpacity(0.15)
                : Colors.grey[300],
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.group,
            color: isCurrentSession ? Colors.orange[700] : Colors.grey[600],
            size: 20,
          ),
        ),
        if (unreadCount > 0) AvatarUnreadBadgeOverlay(count: unreadCount),
      ],
    );

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
          // 会话编号徽标（#abc123），仍跟在首句标题后。
          Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.grey.withOpacity(0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey[700],
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      // 活跃会话（群内 agent 正在该会话处理任务）显示「输入中」，样式与
      // 主页对话列表一致；监听 typingChannelIds 实时更新。
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
            preview.isNotEmpty ? preview : 'No messages',
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
      trailing: (timeText.isNotEmpty || isOrchestrating)
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (isOrchestrating)
                  InkWell(
                    onTap: orchestration == null
                        ? null
                        : () => _showOrchestrationSheet(
                              context,
                              session,
                              orchestration,
                            ),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 9,
                            height: 9,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.6,
                              color: Colors.orange,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '第$orchestrationRound轮',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.orange[800],
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (timeText.isNotEmpty)
                  Text(
                    timeText,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[500],
                    ),
                  ),
              ],
            )
          : null,
      onTap: selectionMode
          ? (selectionEnabled ? onSelectionToggle : null)
          : isCurrentSession
              ? () => Navigator.of(context).pop()
              : () {
                  Navigator.of(context).pop();
                  widget.onSwitchSession(session.id);
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
                    Navigator.pop(context);
                    widget.onBatchDelete(_selectedIds.toList());
                  },
          ),
        ),
      ),
    );
  }
}
