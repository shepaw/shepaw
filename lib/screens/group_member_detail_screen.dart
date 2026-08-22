import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../l10n/l10n_helpers.dart';
import '../models/channel.dart';
import '../models/remote_agent.dart';
import '../peer/models/paired_peer.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/widgets/peer_source_badge.dart';
import '../services/agent_soul_service.dart';
import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import '../widgets/avatar_image.dart';
import 'agent_soul_edit_screen.dart';

/// 群成员详情：展示 Agent 真实头像、简历（描述/能力/模型/Soul）、
/// 本群职责（groupBio，可编辑）与群内角色（admin/member）。
///
/// [onMentionAgent] 由聊天成员面板入口传入；从群详情页进入时不传，
/// 则不展示「在群聊中提及」按钮。
class GroupMemberDetailScreen extends StatefulWidget {
  final RemoteAgent agent;
  final Channel groupChannel;
  final void Function(RemoteAgent agent)? onMentionAgent;

  const GroupMemberDetailScreen({
    super.key,
    required this.agent,
    required this.groupChannel,
    this.onMentionAgent,
  });

  @override
  State<GroupMemberDetailScreen> createState() =>
      _GroupMemberDetailScreenState();
}

class _GroupMemberDetailScreenState extends State<GroupMemberDetailScreen> {
  final LocalDatabaseService _db = LocalDatabaseService();

  late ChannelMember? _member;
  String? _groupBio;
  bool _isAdmin = false;

  String _soul = '';
  bool _soulLoading = true;

  bool _editingBio = false;
  late TextEditingController _bioController;
  bool _savingBio = false;
  bool _changingAdmin = false;

  @override
  void initState() {
    super.initState();
    _member = widget.groupChannel.members
        .where((m) => m.id == widget.agent.id)
        .firstOrNull;
    _groupBio = _member?.groupBio;
    _isAdmin = widget.groupChannel.isAdmin(widget.agent.id);
    _bioController = TextEditingController(text: _groupBio ?? '');
    _loadSoul();
  }

  @override
  void dispose() {
    _bioController.dispose();
    super.dispose();
  }

  /// peer agent 跟随来源设备的 P2P 连接状态，其余 agent 沿用自身状态。
  AgentStatus get _displayStatus {
    if (!widget.agent.isPeerAgent) return widget.agent.status;
    final peerId = widget.agent.sourcePeerId;
    if (peerId == null) return AgentStatus.offline;
    return PeerConnectionManager.instance.getPeerState(peerId) ==
            PeerConnectionState.connected
        ? AgentStatus.online
        : AgentStatus.offline;
  }

  Color _statusColor(AgentStatus status) {
    switch (status) {
      case AgentStatus.online:
        return Colors.green;
      case AgentStatus.offline:
        return Colors.orange;
      case AgentStatus.error:
        return Colors.red;
    }
  }

  Future<void> _loadSoul() async {
    try {
      final soul = await AgentSoulService.instance.getSoul(widget.agent);
      if (!mounted) return;
      setState(() {
        _soul = soul;
        _soulLoading = false;
      });
    } catch (e) {
      LoggerService().warning(
        'Failed to load soul for member detail ${widget.agent.id}: $e',
        tag: 'GroupMemberDetail',
      );
      if (!mounted) return;
      setState(() => _soulLoading = false);
    }
  }

  Future<void> _saveBio() async {
    final l10n = AppLocalizations.of(context);
    final text = _bioController.text.trim();
    final newBio = text.isEmpty ? null : text;
    if (newBio == _groupBio) {
      setState(() => _editingBio = false);
      return;
    }

    setState(() => _savingBio = true);
    try {
      final parentGroupId = widget.groupChannel.groupFamilyId;
      final sessions = await _db.getGroupSessions(parentGroupId);
      for (final session in sessions) {
        await _db.updateChannelMemberGroupBio(
          session.id,
          widget.agent.id,
          newBio,
        );
      }
      if (!mounted) return;
      setState(() {
        _groupBio = newBio;
        _editingBio = false;
        _savingBio = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.groupMemberDetail_saved),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      LoggerService().error('Failed to save group bio', tag: 'GroupMemberDetail', error: e);
      if (!mounted) return;
      setState(() => _savingBio = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// 设为管理员：跨群家族会话先降旧 admin 为 member，再提升当前成员。
  /// 不允许把唯一的管理员降为 member。
  Future<void> _setAdmin(bool makeAdmin) async {
    final l10n = AppLocalizations.of(context);
    final agentId = widget.agent.id;
    if (makeAdmin == _isAdmin) return;

    if (!makeAdmin && widget.groupChannel.adminAgentId == agentId) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.groupMemberDetail_keepAdmin)),
      );
      return;
    }

    setState(() => _changingAdmin = true);
    try {
      final parentGroupId = widget.groupChannel.groupFamilyId;
      final sessions = await _db.getGroupSessions(parentGroupId);
      for (final session in sessions) {
        if (makeAdmin) {
          final oldAdmin = session.adminAgentId;
          if (oldAdmin != null && oldAdmin != agentId) {
            await _db.updateChannelMemberRole(session.id, oldAdmin, 'member');
          }
          await _db.updateChannelMemberRole(session.id, agentId, 'admin');
        }
      }
      if (!mounted) return;
      setState(() {
        _isAdmin = makeAdmin;
        _changingAdmin = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.chat_adminChanged(widget.agent.name)),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      LoggerService().error('Failed to change admin', tag: 'GroupMemberDetail', error: e);
      if (!mounted) return;
      setState(() => _changingAdmin = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to change admin: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _openSoul() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentSoulEditScreen(agent: widget.agent),
      ),
    );
    if (mounted) {
      setState(() => _soulLoading = true);
      await _loadSoul();
    }
  }

  void _mention() {
    final agent = widget.agent;
    Navigator.of(context).pop();
    widget.onMentionAgent?.call(agent);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.groupMemberDetail_title),
        elevation: 1,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _buildHeader(l10n),
          const Divider(height: 1),
          _buildGroupRoleCard(l10n),
          const Divider(height: 1),
          _buildResumeCard(l10n),
          const Divider(height: 1),
          _buildRoleCard(l10n),
          if (widget.onMentionAgent != null) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton.icon(
                onPressed: _mention,
                icon: const Icon(Icons.alternate_email),
                label: Text(l10n.groupMemberDetail_mention),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Header
  // -------------------------------------------------------------------------

  Widget _buildHeader(AppLocalizations l10n) {
    final agent = widget.agent;
    final displayStatus = _displayStatus;
    final displayAgent = agent.isPeerAgent
        ? agent.copyWith(status: displayStatus)
        : agent;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          AvatarImage(
            avatar: agent.avatar.isNotEmpty ? agent.avatar : '🤖',
            size: 72,
            borderRadius: 18,
            fallback: Text(
              agent.name.isNotEmpty ? agent.name[0] : '?',
              style: const TextStyle(fontSize: 28),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  agent.name,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (agent.isPeerAgent) ...[
                const SizedBox(width: 8),
                PeerSourceBadge.fromAgent(agent),
              ],
              if (_isAdmin) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange[100],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    l10n.groupDetail_admin,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.orange[800],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _statusColor(displayStatus).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayAgent.statusIcon,
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(width: 6),
                Text(
                  displayAgent.localizedStatusText(l10n),
                  style: TextStyle(
                    fontSize: 14,
                    color: _statusColor(displayStatus),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 本群职责（groupBio）
  // -------------------------------------------------------------------------

  Widget _buildGroupRoleCard(AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.assignment_ind_outlined,
                  size: 18, color: colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.groupMemberDetail_groupRole,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (!_editingBio)
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: l10n.groupMemberDetail_groupRole,
                  onPressed: () =>
                      setState(() => _editingBio = true),
                ),
            ],
          ),
          const SizedBox(height: 4),
          if (_editingBio) ...[
            TextField(
              controller: _bioController,
              maxLines: 3,
              autofocus: true,
              decoration: InputDecoration(
                hintText: l10n.groupMemberDetail_groupRoleHint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    _bioController.text = _groupBio ?? '';
                    setState(() => _editingBio = false);
                  },
                  child: Text(l10n.common_cancel),
                ),
                TextButton(
                  onPressed: _savingBio ? null : _saveBio,
                  child: Text(l10n.common_save),
                ),
              ],
            ),
          ] else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _groupBio != null && _groupBio!.isNotEmpty
                    ? _groupBio!
                    : l10n.groupMemberDetail_groupRoleEmpty,
                style: TextStyle(
                  fontSize: 13,
                  color: _groupBio != null && _groupBio!.isNotEmpty
                      ? null
                      : colorScheme.onSurfaceVariant,
                  fontStyle: _groupBio != null && _groupBio!.isNotEmpty
                      ? null
                      : FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Agent 简历
  // -------------------------------------------------------------------------

  Widget _buildResumeCard(AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    final agent = widget.agent;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.badge_outlined, size: 18, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                l10n.groupMemberDetail_resume,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 描述
          _buildResumeRow(
            label: l10n.toolModel_description,
            value: _bioValue(agent, l10n),
          ),
          const Divider(height: 16),

          // 能力
          _buildResumeRow(
            label: l10n.agentDetail_capabilities,
            value: agent.capabilities.isNotEmpty
                ? agent.capabilities.join('、')
                : '—',
          ),
          const Divider(height: 16),

          // 模型
          _buildResumeRow(
            label: l10n.agentDetail_model,
            value: _modelName(agent) ?? '—',
          ),
          const Divider(height: 16),

          // 专长 / Soul
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 64,
                child: Text(
                  l10n.agentDetail_systemPrompt,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey[600],
                  ),
                ),
              ),
              Expanded(
                child: _soulLoading
                    ? const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _soul.isNotEmpty
                                ? (_soul.length > 200
                                    ? '${_soul.substring(0, 200)}…'
                                    : _soul)
                                : '—',
                            style: const TextStyle(fontSize: 13),
                          ),
                          if (_soul.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            TextButton.icon(
                              onPressed: _openSoul,
                              icon: const Icon(Icons.psychology_outlined,
                                  size: 16),
                              label: Text(l10n.groupMemberDetail_viewSoul),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _bioValue(RemoteAgent agent, AppLocalizations l10n) {
    final bio = agent.bio?.trim();
    if (bio != null && bio.isNotEmpty) return bio;
    return l10n.groupMemberDetail_bioEmpty;
  }

  String? _modelName(RemoteAgent agent) {
    final metadata = agent.metadata;
    final mainId = metadata['main_model_id'] as String?;
    if (mainId != null && mainId.isNotEmpty) return mainId;
    final model = metadata['llm_model'] as String?;
    if (model != null && model.isNotEmpty) return model;
    return null;
  }

  Widget _buildResumeRow({required String label, required String value}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.grey[600],
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // 群内角色
  // -------------------------------------------------------------------------

  Widget _buildRoleCard(AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.admin_panel_settings_outlined,
                  size: 18, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                l10n.groupMemberDetail_role,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.groupDetail_admin),
            value: _isAdmin,
            activeTrackColor: Colors.orange[200],
            activeThumbColor: Colors.orange[700],
            onChanged: _changingAdmin ? null : _setAdmin,
          ),
        ],
      ),
    );
  }
}
