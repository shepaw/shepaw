import 'package:flutter/material.dart';
import '../../controllers/chat_controller.dart';
import '../../models/channel.dart';
import '../../services/local_database_service.dart';
import '../../l10n/app_localizations.dart';
import 'session_unread_badge.dart';
import 'session_list_header_menu.dart';

/// Session list panel for DM (1-on-1) chat sessions.
///
/// Shows all sessions for a given agent, supports:
/// - Creating new sessions
/// - Switching between sessions
/// - Batch selection & deletion
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
  final VoidCallback? onShowTraces;
  final VoidCallback? onResetSession;
  final VoidCallback? onAllSessionsMarkedRead;

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
    this.onShowTraces,
    this.onResetSession,
    this.onAllSessionsMarkedRead,
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
      onShowTraces: onShowTraces,
      onResetSession: onResetSession,
      onAllSessionsMarkedRead: onAllSessionsMarkedRead,
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
  final VoidCallback? onShowTraces;
  final VoidCallback? onResetSession;
  final VoidCallback? onAllSessionsMarkedRead;

  const _SessionListContent({
    required this.sessions,
    this.currentChannelId,
    required this.controller,
    required this.onNewSession,
    required this.onSwitchSession,
    required this.onBatchDelete,
    this.onShowTraces,
    this.onResetSession,
    this.onAllSessionsMarkedRead,
  });

  @override
  State<_SessionListContent> createState() => _SessionListContentState();
}

class _SessionListContentState extends State<_SessionListContent> {
  bool _isSelectionMode = false;
  Set<String> _selectedIds = {};
  int _listRefreshTick = 0;
  final _databaseService = LocalDatabaseService();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Column(
      children: [
        _buildHeader(l10n),
        const Divider(height: 1),
        Expanded(child: _buildList(l10n)),
        if (_isSelectionMode) _buildBottomBar(l10n),
      ],
    );
  }

  Future<void> _markAllSessionsRead() async {
    for (final session in widget.sessions) {
      await _databaseService.markChannelMessagesAsRead(session.id);
    }
    if (!mounted) return;
    setState(() => _listRefreshTick++);
    widget.onAllSessionsMarkedRead?.call();
  }

  Widget _buildHeader(AppLocalizations l10n) {
    if (_isSelectionMode) {
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
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        children: [
          Text(
            l10n.chat_sessions,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          Text(
            l10n.chat_sessionsCount(widget.sessions.length),
            style: TextStyle(fontSize: 14, color: Colors.grey[600]),
          ),
          SessionListHeaderMoreButton(
            sessions: widget.sessions,
            databaseService: _databaseService,
            listRefreshTick: _listRefreshTick,
            onMarkAll: _markAllSessionsRead,
            onShowTraces: widget.onShowTraces,
            onResetSession: widget.onResetSession,
            onEnterSelectionMode: widget.sessions.length > 1
                ? () => setState(() => _isSelectionMode = true)
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildList(AppLocalizations l10n) {
    return ListView.builder(
      itemCount: widget.sessions.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          if (_isSelectionMode) return const SizedBox.shrink();
          return _buildNewSessionItem(context, l10n);
        }
        final session = widget.sessions[index - 1];
        final isCurrent = session.id == widget.currentChannelId;
        return FutureBuilder<(Map<String, dynamic>?, int)>(
          key: ValueKey('${session.id}_$_listRefreshTick'),
          future: _loadSessionPreview(session.id, isCurrent),
          builder: (context, snapshot) {
            final latestMessage = snapshot.data?.$1;
            final unreadCount = snapshot.data?.$2 ?? 0;
            final tile = _buildSessionTile(
              context,
              session,
              isCurrent,
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
      onTap: () {
        Navigator.pop(context);
        widget.onNewSession();
      },
    );
  }

  Future<(Map<String, dynamic>?, int)> _loadSessionPreview(
    String channelId,
    bool isCurrent,
  ) async {
    final latestMessage =
        await _databaseService.getLatestChannelMessage(channelId);
    var unreadCount = await _databaseService.getUnreadCountByChannel(channelId);
    if (isCurrent) unreadCount = 0;
    return (latestMessage, unreadCount);
  }

  Widget _buildSessionTile(
    BuildContext context,
    Channel session,
    bool isCurrentSession,
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
    final preview = latestMessage?['content'] as String? ??
        (isBound ? (session.description ?? '') : 'No messages');
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

    final avatar = Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isCurrentSession
                ? Theme.of(context).primaryColor
                : isSheBound
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
            color: isCurrentSession
                ? Colors.white
                : isSheBound
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

    return ListTile(
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
              session.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
          if (isCurrentSession)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Current',
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).primaryColor,
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
                fontSize: 13,
                color: Colors.green[600],
                fontStyle: FontStyle.italic,
              ),
            );
          }
          return Text(
            preview.isNotEmpty
                ? preview
                : (isGroupBound ? 'Group-bound session' : 'No messages'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey[600],
            ),
          );
        },
      ),
      trailing: timeText.isNotEmpty
          ? Text(
              timeText,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[500],
              ),
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
