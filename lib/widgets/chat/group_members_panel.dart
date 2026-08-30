import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/channel.dart';
import '../../models/remote_agent.dart';
import '../../peer/widgets/peer_source_badge.dart';
import '../../theme/app_theme.dart';
import '../../utils/layout_utils.dart';
import '../agent_list_avatar.dart';

/// Snapshot returned after adding a group member so the panel can refresh.
class GroupMembersPanelSnapshot {
  final List<RemoteAgent> groupAgents;
  final List<ChannelMember> channelMembers;
  final String? adminAgentId;

  const GroupMembersPanelSnapshot({
    required this.groupAgents,
    required this.channelMembers,
    this.adminAgentId,
  });
}

/// Group chat member list panel. Pair with [LayoutUtils.showRightDrawer] on
/// desktop or a full-screen [Scaffold] route on mobile (see peer agent list).
class GroupMembersPanel extends StatefulWidget {
  final List<RemoteAgent> groupAgents;
  final String channelId;
  final String? adminAgentId;
  final List<ChannelMember> channelMembers;
  final Future<GroupMembersPanelSnapshot?> Function(BuildContext panelContext) onAddMember;
  final Future<GroupMembersPanelSnapshot?> Function(List<RemoteAgent> agents) onBatchRemoveMembers;
  final Future<List<ChannelMember>> Function(RemoteAgent agent, String? newGroupBio) onSaveGroupBio;
  final Future<void> Function(RemoteAgent agent) onChangeAdmin;
  final void Function(RemoteAgent agent) onMentionAgent;
  /// 点击成员条目打开成员详情；为 null 时点击行为回退为 [onMentionAgent]。
  final void Function(RemoteAgent agent)? onOpenMemberDetail;

  const GroupMembersPanel({
    super.key,
    required this.groupAgents,
    required this.channelId,
    this.adminAgentId,
    this.channelMembers = const [],
    required this.onAddMember,
    required this.onBatchRemoveMembers,
    required this.onSaveGroupBio,
    required this.onChangeAdmin,
    required this.onMentionAgent,
    this.onOpenMemberDetail,
  });

  @override
  State<GroupMembersPanel> createState() => _GroupMembersPanelState();
}

class _GroupMembersPanelState extends State<GroupMembersPanel> {
  String? _editingAgentId;
  late TextEditingController _editController;
  late List<RemoteAgent> _groupAgents;
  late List<ChannelMember> _channelMembers;
  bool _editingIsAdmin = false;
  late String? _currentAdminAgentId;
  bool _isSelectionMode = false;
  Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController();
    _groupAgents = List.of(widget.groupAgents);
    _channelMembers = List.of(widget.channelMembers);
    _currentAdminAgentId = widget.adminAgentId;
  }

  @override
  void didUpdateWidget(GroupMembersPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupAgents != widget.groupAgents) {
      _groupAgents = List.of(widget.groupAgents);
    }
    if (oldWidget.channelMembers != widget.channelMembers) {
      _channelMembers = List.of(widget.channelMembers);
    }
    if (oldWidget.adminAgentId != widget.adminAgentId) {
      _currentAdminAgentId = widget.adminAgentId;
    }
  }

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedIds.clear();
    });
  }

  void _enterSelectionMode() {
    setState(() {
      _editingAgentId = null;
      _isSelectionMode = true;
      _selectedIds.clear();
    });
  }

  void _startEditing(RemoteAgent agent) {
    final member = _channelMembers.where((m) => m.id == agent.id).firstOrNull;
    _editController.text = member?.groupBio ?? '';
    setState(() {
      _editingAgentId = agent.id;
      _editingIsAdmin = _currentAdminAgentId == agent.id;
    });
  }

  void _cancelEditing() {
    setState(() { _editingAgentId = null; });
  }

  Future<void> _saveEditing(RemoteAgent agent) async {
    final text = _editController.text.trim();
    final newGroupBio = text.isEmpty ? null : text;
    final updatedMembers = await widget.onSaveGroupBio(agent, newGroupBio);
    final wasAdmin = _currentAdminAgentId == agent.id;
    if (_editingIsAdmin && !wasAdmin) {
      await widget.onChangeAdmin(agent);
      if (mounted) setState(() { _currentAdminAgentId = agent.id; });
    }
    if (mounted) setState(() { _channelMembers = updatedMembers; _editingAgentId = null; });
  }

  Future<void> _resetGroupBio(RemoteAgent agent) async {
    final updatedMembers = await widget.onSaveGroupBio(agent, null);
    if (mounted) setState(() { _channelMembers = updatedMembers; _editingAgentId = null; });
  }

  Future<void> _handleAddMember() async {
    final snapshot = await widget.onAddMember(context);
    if (snapshot == null || !mounted) return;
    setState(() {
      _groupAgents = List.of(snapshot.groupAgents);
      _channelMembers = List.of(snapshot.channelMembers);
      _currentAdminAgentId = snapshot.adminAgentId;
    });
  }

  Future<void> _handleBatchDelete() async {
    if (_selectedIds.isEmpty) return;

    final agents = _groupAgents
        .where((agent) => _selectedIds.contains(agent.id))
        .toList();
    final snapshot = await widget.onBatchRemoveMembers(agents);
    if (!mounted) return;

    if (snapshot != null) {
      setState(() {
        _groupAgents = List.of(snapshot.groupAgents);
        _channelMembers = List.of(snapshot.channelMembers);
        _currentAdminAgentId = snapshot.adminAgentId;
        _isSelectionMode = false;
        _selectedIds.clear();
      });
    }
  }

  void _toggleSelection(String agentId) {
    setState(() {
      if (_selectedIds.contains(agentId)) {
        _selectedIds.remove(agentId);
      } else {
        _selectedIds.add(agentId);
      }
    });
  }

  void _selectAllMembers() {
    setState(() {
      _selectedIds = _groupAgents.map((agent) => agent.id).toSet();
    });
  }

  void _invertSelection() {
    setState(() {
      final newSet = <String>{};
      for (final agent in _groupAgents) {
        if (!_selectedIds.contains(agent.id)) {
          newSet.add(agent.id);
        }
      }
      _selectedIds = newSet;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDesktop = LayoutUtils.isDesktopLayout(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(l10n, isDesktop),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              ..._groupAgents.map((agent) => _buildAgentTile(context, l10n, agent)),
              const SizedBox(height: 8),
            ],
          ),
        ),
        if (_isSelectionMode) _buildBottomBar(l10n),
      ],
    );
  }

  Widget _buildHeader(AppLocalizations l10n, bool isDesktop) {
    if (_isSelectionMode) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _exitSelectionMode,
                ),
                Text(
                  l10n.chat_groupMembers,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _selectAllMembers,
                  child: Text(l10n.osTool_selectAll),
                ),
                TextButton(
                  onPressed: _invertSelection,
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
      padding: EdgeInsets.fromLTRB(16, isDesktop ? 16 : 8, 8, 8),
      child: Row(
        children: [
          if (isDesktop)
            Expanded(
              child: Text(
                l10n.chat_groupMembersCount(_groupAgents.length),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            )
          else
            const Spacer(),
          if (_groupAgents.length > 1)
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
              tooltip: l10n.chat_removeMember,
              onPressed: _enterSelectionMode,
            ),
          TextButton.icon(
            onPressed: _handleAddMember,
            icon: const Icon(Icons.person_add, size: 20),
            label: Text(l10n.chat_add),
          ),
        ],
      ),
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
            onPressed: _selectedIds.isEmpty ? null : _handleBatchDelete,
          ),
        ),
      ),
    );
  }

  Widget _buildAgentTile(BuildContext context, AppLocalizations l10n, RemoteAgent agent) {
    if (_isSelectionMode) {
      return ListTile(
        leading: Checkbox(
          value: _selectedIds.contains(agent.id),
          onChanged: (_) => _toggleSelection(agent.id),
        ),
        title: _buildAgentTitle(agent),
        subtitle: _buildAgentSubtitle(agent),
        onTap: () => _toggleSelection(agent.id),
      );
    }

    final member = _channelMembers.where((m) => m.id == agent.id).firstOrNull;
    final groupBio = member?.groupBio;
    final displayBio = groupBio ?? agent.bio;
    final hasGroupBio = groupBio != null && groupBio.isNotEmpty;
    final isEditing = _editingAgentId == agent.id;

    if (isEditing) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _buildAgentAvatar(agent, size: 32),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          l10n.chat_groupRoleTitle(agent.name),
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (agent.isPeerAgent) ...[
                        const SizedBox(width: 6),
                        PeerSourceBadge.fromAgent(agent),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (agent.bio != null && agent.bio!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Default: ${agent.bio}', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
              ),
            const SizedBox(height: 8),
            TextField(controller: _editController, maxLines: 3, autofocus: true, decoration: InputDecoration(labelText: l10n.chat_groupCapabilityLabel, hintText: l10n.chat_groupCapabilityHint, border: const OutlineInputBorder(), isDense: true)),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () { setState(() { _editingIsAdmin = !_editingIsAdmin; }); },
              child: Row(
                children: [
                  SizedBox(height: 32, width: 40, child: FittedBox(fit: BoxFit.scaleDown, child: Switch(value: _editingIsAdmin, onChanged: (v) { setState(() { _editingIsAdmin = v; }); }, activeTrackColor: Colors.orange[200], activeThumbColor: Colors.orange[700]))),
                  const SizedBox(width: 4),
                  Icon(Icons.admin_panel_settings, size: 18, color: _editingIsAdmin ? Colors.orange[700] : Colors.grey[400]),
                  const SizedBox(width: 4),
                  Text(l10n.createGroup_setAsAdmin, style: TextStyle(fontSize: 13, color: _editingIsAdmin ? Colors.orange[700] : Colors.grey[600], fontWeight: _editingIsAdmin ? FontWeight.w600 : FontWeight.normal)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: _cancelEditing, child: Text(l10n.common_cancel)),
                if (hasGroupBio) TextButton(onPressed: () => _resetGroupBio(agent), child: Text(l10n.chat_resetButton, style: TextStyle(color: Colors.orange[700]))),
                TextButton(onPressed: () => _saveEditing(agent), child: Text(l10n.common_save)),
              ],
            ),
            const Divider(height: 1),
          ],
        ),
      );
    }

    return ListTile(
      leading: _buildAgentAvatar(agent),
      title: _buildAgentTitle(agent),
      subtitle: _buildAgentSubtitle(agent, displayBio: displayBio, hasGroupBio: hasGroupBio),
      trailing: IconButton(
        icon: const Icon(Icons.edit_note, size: 20, color: AppColors.primary),
        tooltip: 'Edit group role',
        onPressed: () => _startEditing(agent),
      ),
      onTap: () {
        if (widget.onOpenMemberDetail != null) {
          widget.onOpenMemberDetail!(agent);
        } else {
          widget.onMentionAgent(agent);
        }
      },
    );
  }

  Widget _buildAgentAvatar(RemoteAgent agent, {double size = 40}) {
    return AgentListAvatar(avatar: agent.avatar, name: agent.name, size: size);
  }

  Widget _buildAgentTitle(RemoteAgent agent) {
    return Row(
      children: [
        Flexible(child: Text(agent.name, overflow: TextOverflow.ellipsis)),
        if (agent.isPeerAgent) ...[
          const SizedBox(width: 6),
          PeerSourceBadge.fromAgent(agent),
        ],
        if (_currentAdminAgentId == agent.id) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.orange[100],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Admin',
              style: TextStyle(
                fontSize: 11,
                color: Colors.orange[800],
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget? _buildAgentSubtitle(
    RemoteAgent agent, {
    String? displayBio,
    bool hasGroupBio = false,
  }) {
    final member = _channelMembers.where((m) => m.id == agent.id).firstOrNull;
    final groupBio = member?.groupBio;
    final bio = displayBio ?? groupBio ?? agent.bio;
    final customBio = hasGroupBio || (groupBio != null && groupBio.isNotEmpty);

    if (bio != null && bio.isNotEmpty) {
      return Text(
        bio,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: customBio ? const TextStyle(color: AppColors.primary, fontStyle: FontStyle.italic) : null,
      );
    }

    return Text(
      'Set group role...',
      style: TextStyle(color: Colors.grey[400], fontSize: 13),
    );
  }
}
