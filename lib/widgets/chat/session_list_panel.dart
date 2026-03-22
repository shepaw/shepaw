import 'package:flutter/material.dart';
import '../../controllers/chat_controller.dart';
import '../../models/channel.dart';
import '../../services/local_database_service.dart';
import '../../l10n/app_localizations.dart';

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
  });

  @override
  Widget build(BuildContext context) {
    return _SessionListContent(
      sessions: sessions,
      currentChannelId: currentChannelId,
      onNewSession: onNewSession,
      onSwitchSession: onSwitchSession,
      onBatchDelete: onBatchDelete,
      onShowTraces: onShowTraces,
    );
  }
}

class _SessionListContent extends StatefulWidget {
  final List<Channel> sessions;
  final String? currentChannelId;
  final VoidCallback onNewSession;
  final ValueChanged<String> onSwitchSession;
  final ValueChanged<List<String>> onBatchDelete;
  final VoidCallback? onShowTraces;

  const _SessionListContent({
    required this.sessions,
    this.currentChannelId,
    required this.onNewSession,
    required this.onSwitchSession,
    required this.onBatchDelete,
    this.onShowTraces,
  });

  @override
  State<_SessionListContent> createState() => _SessionListContentState();
}

class _SessionListContentState extends State<_SessionListContent> {
  bool _isSelectionMode = false;
  Set<String> _selectedIds = {};
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
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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
          if (widget.onShowTraces != null)
            IconButton(
              icon: const Icon(Icons.psychology_outlined, size: 20),
              tooltip: 'Traces',
              onPressed: widget.onShowTraces,
            ),
          if (widget.sessions.length > 1)
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
              tooltip: l10n.chat_selectSessions,
              onPressed: () => setState(() {
                _isSelectionMode = true;
              }),
            ),
          Text(
            l10n.chat_sessionsCount(widget.sessions.length),
            style: TextStyle(fontSize: 14, color: Colors.grey[600]),
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
        return FutureBuilder<Map<String, dynamic>?>(
          future: _databaseService.getLatestChannelMessage(session.id),
          builder: (context, snapshot) {
            final tile = _buildSessionTile(context, session, isCurrent, snapshot.data);
            if (!_isSelectionMode) return tile;
            return ListTile(
              leading: Checkbox(
                value: _selectedIds.contains(session.id),
                onChanged: isCurrent
                    ? null
                    : (val) => setState(() {
                          if (val == true) {
                            _selectedIds.add(session.id);
                          } else {
                            _selectedIds.remove(session.id);
                          }
                        }),
              ),
              title: tile,
              contentPadding: EdgeInsets.zero,
              onTap: isCurrent
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

  Widget _buildSessionTile(BuildContext context, Channel session, bool isCurrentSession, Map<String, dynamic>? latestMessage) {
    final preview = latestMessage?['content'] as String? ?? 'No messages';
    final createdAtStr = latestMessage?['created_at'] as String?;
    String timeText = '';
    if (createdAtStr != null) {
      try {
        final dt = DateTime.parse(createdAtStr);
        final now = DateTime.now();
        if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
          timeText = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
        } else {
          timeText = '${dt.month}/${dt.day}';
        }
      } catch (_) {}
    }

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: isCurrentSession ? Theme.of(context).primaryColor : Colors.grey[300],
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.chat_bubble_outline,
          color: isCurrentSession ? Colors.white : Colors.grey[600],
          size: 20,
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              session.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
      subtitle: Text(
        preview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          color: Colors.grey[600],
        ),
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
      onTap: isCurrentSession
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
