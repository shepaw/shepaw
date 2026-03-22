import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/channel.dart';
import '../models/agent.dart';
import '../services/local_api_service.dart';
import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import 'chat_screen.dart';

/// Group detail screen, similar to RemoteAgentDetailScreen but for groups.
/// Supports an optional [startInEditMode] to open directly in edit mode.
class GroupDetailScreen extends StatefulWidget {
  final Channel channel;
  final bool startInEditMode;

  const GroupDetailScreen({
    super.key,
    required this.channel,
    this.startInEditMode = false,
  });

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  late Channel _channel;
  final LocalApiService _apiService = LocalApiService();
  final LocalDatabaseService _databaseService = LocalDatabaseService();
  Map<String, Agent> _agentMap = {};
  bool _isDeleting = false;

  // Edit mode state
  bool _isEditing = false;
  late TextEditingController _nameController;
  late TextEditingController _descController;
  late TextEditingController _systemPromptController;
  late String _selectedMentionMode;
  late bool _planningMode;
  late bool _flowMode;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _channel = widget.channel;
    _loadAgents();
    _initEditControllers();
    if (widget.startInEditMode) {
      _isEditing = true;
    }
  }

  void _initEditControllers() {
    _nameController = TextEditingController(text: _channel.name);
    _descController = TextEditingController(text: _channel.description ?? '');
    _systemPromptController = TextEditingController(text: _channel.systemPrompt ?? '');
    _selectedMentionMode = _channel.effectiveMentionMode;
    _planningMode = _channel.planningMode;
    _flowMode = _channel.flowMode;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _systemPromptController.dispose();
    super.dispose();
  }

  Future<void> _loadAgents() async {
    try {
      final agents = await _apiService.getAgents();
      final map = <String, Agent>{};
      for (final agent in agents) {
        map[agent.id] = agent;
      }
      if (mounted) {
        setState(() {
          _agentMap = map;
        });
      }
    } catch (e) {
      LoggerService().error('Failed to load agents for group detail', tag: 'GroupDetail', error: e);
    }
  }

  void _enterEditMode() {
    // Reset controllers to current channel values
    _nameController.text = _channel.name;
    _descController.text = _channel.description ?? '';
    _systemPromptController.text = _channel.systemPrompt ?? '';
    _selectedMentionMode = _channel.effectiveMentionMode;
    _planningMode = _channel.planningMode;
    _flowMode = _channel.flowMode;
    setState(() => _isEditing = true);
  }

  void _cancelEdit() {
    setState(() => _isEditing = false);
  }

  Future<void> _saveEdit() async {
    final l10n = AppLocalizations.of(context);
    final newName = _nameController.text.trim();
    if (newName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.chat_groupNameEmpty)),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final newSystemPrompt = _systemPromptController.text.trim();
      final newDesc = _descController.text.trim();
      final updated = Channel(
        id: _channel.id,
        name: newName,
        type: _channel.type,
        members: _channel.members,
        createdBy: _channel.createdBy,
        createdAt: _channel.createdAt,
        description: newDesc.isNotEmpty ? newDesc : null,
        systemPrompt: newSystemPrompt.isNotEmpty ? newSystemPrompt : null,
        avatar: _channel.avatar,
        isPrivate: _channel.isPrivate,
        maxLoopRounds: _channel.maxLoopRounds,
        mentionMode: _selectedMentionMode,
        planningMode: _planningMode,
        flowMode: _flowMode,
        parentGroupId: _channel.parentGroupId,
      );
      await _databaseService.updateChannel(updated);
      if (!mounted) return;
      if (widget.startInEditMode) {
        // Opened directly in edit mode (e.g. from chat screen), pop with result
        Navigator.pop(context, updated);
      } else {
        setState(() {
          _channel = updated;
          _isEditing = false;
          _isSaving = false;
        });
      }
    } catch (e) {
      LoggerService().error('Failed to save group info', tag: 'GroupDetail', error: e);
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? l10n.groupDetail_editTitle : l10n.groupDetail_title),
        elevation: 1,
        actions: _isEditing
            ? [
                TextButton(
                  onPressed: _isSaving ? null : _cancelEdit,
                  child: Text(l10n.common_cancel),
                ),
                TextButton(
                  onPressed: _isSaving ? null : _saveEdit,
                  child: _isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          l10n.common_save,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: l10n.groupDetail_editGroup,
                  onPressed: _enterEditMode,
                ),
              ],
      ),
      body: _isEditing ? _buildEditBody(l10n) : _buildDetailBody(l10n),
    );
  }

  Widget _buildDetailBody(AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    final memberCount = _channel.members.where((m) => m.id != 'user').length;

    return ListView(
      children: [
        // Header section
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: Colors.blue[100],
                  borderRadius: BorderRadius.circular(20),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.group, size: 40, color: Colors.blue),
              ),
              const SizedBox(height: 16),
              Text(
                _channel.name,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (_channel.description != null &&
                  _channel.description!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _channel.description!,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                l10n.contacts_memberCount(memberCount),
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[500],
                ),
              ),
            ],
          ),
        ),

        const Divider(height: 1),

        // System prompt section
        if (_channel.systemPrompt != null &&
            _channel.systemPrompt!.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.groupDetail_systemPrompt,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _channel.systemPrompt!,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
        ],

        // Max loop rounds section
        if (_channel.maxLoopRounds != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.loop, size: 16, color: Colors.grey[600]),
                const SizedBox(width: 8),
                Text(
                  l10n.groupDetail_maxLoopRounds,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[600],
                  ),
                ),
                const Spacer(),
                Text(
                  '${_channel.maxLoopRounds}',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
        ],

        // Members section
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            l10n.groupDetail_members,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
        ),
        ..._channel.members
            .where((m) => m.id != 'user')
            .map((member) => _buildMemberTile(member)),

        const SizedBox(height: 24),

        // Actions
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.icon(
            onPressed: () => _startChat(),
            icon: const Icon(Icons.chat_bubble_outline),
            label: Text(l10n.groupDetail_startChat),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            onPressed: _isDeleting ? null : () => _showDeleteDialog(),
            icon: _isDeleting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_outline, color: Colors.red),
            label: Text(
              l10n.groupDetail_deleteGroup,
              style: const TextStyle(color: Colors.red),
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              side: const BorderSide(color: Colors.red),
            ),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildEditBody(AppLocalizations l10n) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: StatefulBuilder(
        builder: (context, setEditState) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Group avatar (read-only for now)
            Center(
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: Colors.blue[100],
                  borderRadius: BorderRadius.circular(20),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.group, size: 40, color: Colors.blue),
              ),
            ),
            const SizedBox(height: 24),

            // Basic info card
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _nameController,
                      decoration: InputDecoration(
                        labelText: l10n.chat_groupName,
                        border: const OutlineInputBorder(),
                      ),
                      autofocus: widget.startInEditMode,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _descController,
                      decoration: InputDecoration(
                        labelText: l10n.chat_groupDescriptionOptional,
                        border: const OutlineInputBorder(),
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _systemPromptController,
                      decoration: InputDecoration(
                        labelText: l10n.chat_groupSystemPrompt,
                        hintText: l10n.chat_groupSystemPromptHint,
                        border: const OutlineInputBorder(),
                      ),
                      maxLines: 4,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Behavior config card
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<String>(
                      value: _selectedMentionMode,
                      decoration: InputDecoration(
                        labelText: l10n.chat_mentionMode,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.alternate_email),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'adminOnly',
                          child: Text(l10n.chat_mentionModeAdminOnly),
                        ),
                        DropdownMenuItem(
                          value: 'allMembers',
                          child: Text(l10n.chat_mentionModeAllMembers),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setEditState(() => _selectedMentionMode = value);
                        }
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, left: 4),
                      child: Text(
                        _selectedMentionMode == 'allMembers'
                            ? l10n.chat_mentionModeAllMembersDesc
                            : l10n.chat_mentionModeAdminOnlyDesc,
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      title: Text(l10n.chat_planningMode),
                      subtitle: Text(l10n.chat_planningModeDesc, style: const TextStyle(fontSize: 12)),
                      secondary: const Icon(Icons.assignment_turned_in_outlined),
                      value: _planningMode,
                      onChanged: _flowMode ? null : (v) => setEditState(() => _planningMode = v),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    ),
                    SwitchListTile(
                      title: Text(l10n.chat_flowMode),
                      subtitle: Text(l10n.chat_flowModeDesc, style: const TextStyle(fontSize: 12)),
                      secondary: const Icon(Icons.account_tree_outlined),
                      value: _flowMode,
                      onChanged: (v) => setEditState(() => _flowMode = v),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildMemberTile(ChannelMember member) {
    final l10n = AppLocalizations.of(context);
    final agent = _agentMap[member.id];
    final isAdmin = member.role == 'admin';

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: agent != null && agent.avatar.length <= 2
            ? Text(agent.avatar, style: const TextStyle(fontSize: 18))
            : Text(
                agent?.name.isNotEmpty == true ? agent!.name[0] : '?',
                style: const TextStyle(fontSize: 18),
              ),
      ),
      title: Text(
        agent?.name ?? member.id,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      subtitle: member.groupBio != null && member.groupBio!.isNotEmpty
          ? Text(
              member.groupBio!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            )
          : (agent?.bio != null && agent!.bio!.isNotEmpty
              ? Text(
                  agent.bio!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                )
              : null),
      trailing: isAdmin
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.orange[50],
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.orange[200]!),
              ),
              child: Text(
                l10n.groupDetail_admin,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.orange[800],
                  fontWeight: FontWeight.w500,
                ),
              ),
            )
          : Text(
              l10n.groupDetail_member,
              style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            ),
    );
  }

  Future<void> _startChat() async {
    final latestChannelId = await _databaseService
        .getLatestActiveGroupChannel(_channel.groupFamilyId);
    final targetChannelId = latestChannelId ?? _channel.id;

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(channelId: targetChannelId),
      ),
    );
  }

  void _showDeleteDialog() {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.groupDetail_confirmDelete),
        content: Text(l10n.groupDetail_deleteContent(_channel.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteGroup();
            },
            child: Text(
              l10n.common_delete,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteGroup() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _isDeleting = true);

    try {
      // Delete all sessions in this group family
      final sessions =
          await _databaseService.getGroupSessions(_channel.groupFamilyId);
      for (final session in sessions) {
        await _databaseService.deleteChannelMessages(session.id);
        await _databaseService.deleteChannel(session.id);
      }
      // Delete the parent group itself
      await _databaseService.deleteChannelMessages(_channel.id);
      await _databaseService.deleteChannel(_channel.id);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.groupDetail_deleted(_channel.name))),
      );
      Navigator.pop(context, true); // return true to indicate deletion
    } catch (e) {
      LoggerService().error('Failed to delete group', tag: 'GroupDetail', error: e);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(l10n.groupDetail_deleteFailed(e.toString()))),
      );
      setState(() => _isDeleting = false);
    }
  }
}
