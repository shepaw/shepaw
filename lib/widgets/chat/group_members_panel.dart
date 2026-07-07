import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/channel.dart';
import '../../models/remote_agent.dart';
import '../../peer/widgets/peer_source_badge.dart';
import '../../theme/app_theme.dart';
import '../../utils/layout_utils.dart';

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
  final Future<GroupMembersPanelSnapshot?> Function() onAddMember;
  final Future<void> Function(RemoteAgent agent) onRemoveMember;
  final Future<List<ChannelMember>> Function(RemoteAgent agent, String? newGroupBio) onSaveGroupBio;
  final Future<void> Function(RemoteAgent agent) onChangeAdmin;
  final void Function(RemoteAgent agent) onMentionAgent;

  const GroupMembersPanel({
    super.key,
    required this.groupAgents,
    required this.channelId,
    this.adminAgentId,
    this.channelMembers = const [],
    required this.onAddMember,
    required this.onRemoveMember,
    required this.onSaveGroupBio,
    required this.onChangeAdmin,
    required this.onMentionAgent,
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
    final snapshot = await widget.onAddMember();
    if (snapshot == null || !mounted) return;
    setState(() {
      _groupAgents = List.of(snapshot.groupAgents);
      _channelMembers = List.of(snapshot.channelMembers);
      _currentAdminAgentId = snapshot.adminAgentId;
    });
  }

  Future<void> _handleRemoveMember(RemoteAgent agent) async {
    Navigator.pop(context);
    await widget.onRemoveMember(agent);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDesktop = LayoutUtils.isDesktopLayout(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isDesktop)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.chat_groupMembersCount(_groupAgents.length),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, isDesktop ? 4 : 8, 16, 8),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _handleAddMember,
              icon: const Icon(Icons.person_add, size: 20),
              label: Text(l10n.chat_add),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              ..._groupAgents.map((agent) => _buildAgentTile(context, l10n, agent)),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAgentTile(BuildContext context, AppLocalizations l10n, RemoteAgent agent) {
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
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(color: AppColors.primaryContainer, borderRadius: BorderRadius.circular(8)),
                  alignment: Alignment.center,
                  child: Text(agent.name.isNotEmpty ? agent.name[0].toUpperCase() : '?', style: const TextStyle(color: AppColors.primaryDark, fontWeight: FontWeight.bold, fontSize: 13)),
                ),
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
      leading: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(color: AppColors.primaryContainer, borderRadius: BorderRadius.circular(10)),
        alignment: Alignment.center,
        child: Text(agent.name.isNotEmpty ? agent.name[0].toUpperCase() : '?', style: const TextStyle(color: AppColors.primaryDark, fontWeight: FontWeight.bold)),
      ),
      title: Row(
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
              decoration: BoxDecoration(color: Colors.orange[100], borderRadius: BorderRadius.circular(12)),
              child: Text('Admin', style: TextStyle(fontSize: 11, color: Colors.orange[800], fontWeight: FontWeight.w600)),
            ),
          ],
        ],
      ),
      subtitle: displayBio != null && displayBio.isNotEmpty
          ? Text(displayBio, maxLines: 1, overflow: TextOverflow.ellipsis, style: hasGroupBio ? const TextStyle(color: AppColors.primary, fontStyle: FontStyle.italic) : null)
          : Text('Set group role...', style: TextStyle(color: Colors.grey[400], fontSize: 13)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(icon: const Icon(Icons.edit_note, size: 20, color: AppColors.primary), tooltip: 'Edit group role', onPressed: () => _startEditing(agent)),
          IconButton(icon: Icon(Icons.remove_circle_outline, color: Colors.red[300]), onPressed: () => _handleRemoveMember(agent)),
        ],
      ),
      onTap: () => widget.onMentionAgent(agent),
    );
  }
}
