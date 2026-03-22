import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../l10n/app_localizations.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../services/local_api_service.dart';
import '../services/local_database_service.dart';
import 'chat_screen.dart';

class CreateGroupScreen extends StatefulWidget {
  /// Optional callback used in desktop embedded mode.
  /// When provided, called with the new channelId instead of pushing ChatScreen.
  final void Function(String channelId)? onGroupCreated;

  const CreateGroupScreen({Key? key, this.onGroupCreated}) : super(key: key);

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameController = TextEditingController();
  final _purposeController = TextEditingController();
  final _systemPromptController = TextEditingController();
  final _maxRoundsController = TextEditingController(text: '50');
  final Set<String> _selectedAgentIds = {};
  final Map<String, TextEditingController> _groupBioControllers = {};
  String? _adminAgentId;
  String _mentionMode = 'adminOnly';
  bool _planningMode = false;
  bool _flowMode = false;
  final LocalApiService _apiService = LocalApiService();
  final LocalDatabaseService _databaseService = LocalDatabaseService();
  List<Agent> _agents = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAgents();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _purposeController.dispose();
    _systemPromptController.dispose();
    _maxRoundsController.dispose();
    for (final controller in _groupBioControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadAgents() async {
    try {
      final agents = await _apiService.getAgents();
      if (mounted) {
        setState(() {
          _agents = agents;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _createGroup() async {
    final l10n = AppLocalizations.of(context);
    final name = _nameController.text.trim();
    final purpose = _purposeController.text.trim();
    final systemPrompt = _systemPromptController.text.trim();
    final maxRoundsText = _maxRoundsController.text.trim();
    final maxLoopRounds = maxRoundsText.isNotEmpty ? int.tryParse(maxRoundsText) : null;

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.createGroup_nameRequired)),
      );
      return;
    }

    if (_selectedAgentIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.createGroup_agentRequired)),
      );
      return;
    }

    // Auto-set admin if only 1 agent selected, otherwise require selection
    final effectiveAdminId = _selectedAgentIds.length == 1
        ? _selectedAgentIds.first
        : _adminAgentId;

    if (_selectedAgentIds.length >= 2 && effectiveAdminId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.createGroup_adminRequired)),
      );
      return;
    }

    // Generate a UUID channel ID for the group
    final channelId = 'group_${const Uuid().v4()}';
    const userId = 'user';

    // Build members with roles
    final now = DateTime.now().millisecondsSinceEpoch;
    final members = <ChannelMember>[
      ChannelMember(id: userId, type: 'user', role: 'member', joinedAt: now),
      ..._selectedAgentIds.map((agentId) => ChannelMember(
        id: agentId,
        type: 'agent',
        role: agentId == effectiveAdminId ? 'admin' : 'member',
        joinedAt: now,
        groupBio: _groupBioControllers[agentId]?.text.trim().isNotEmpty == true
            ? _groupBioControllers[agentId]!.text.trim()
            : null,
      )),
    ];

    final channel = Channel(
      id: channelId,
      name: name,
      type: 'group',
      members: members,
      description: purpose.isNotEmpty ? purpose : null,
      systemPrompt: systemPrompt.isNotEmpty ? systemPrompt : null,
      maxLoopRounds: maxLoopRounds,
      mentionMode: _mentionMode != 'adminOnly' ? _mentionMode : null,
      planningMode: _planningMode,
      flowMode: _flowMode,
      isPrivate: true,
    );

    await _databaseService.createChannel(channel, userId);

    if (mounted) {
      if (widget.onGroupCreated != null) {
        widget.onGroupCreated!(channelId);
      } else {
        // Replace CreateGroupScreen with ChatScreen.
        // HomeScreen's .then((_) => _loadAgents()) fires on replacement,
        // refreshing the group list while user is in the chat.
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ChatScreen(channelId: channelId),
          ),
        );
      }
    }
  }

  Widget _buildAgentAvatar(Agent agent, {double size = 40, double fontSize = 28}) {
    if (agent.avatar.length <= 2) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Text(
            agent.avatar,
            style: TextStyle(fontSize: fontSize),
          ),
        ),
      );
    }
    // Image URL or file path
    final ImageProvider imageProvider;
    if (agent.avatar.startsWith('/') && !agent.avatar.startsWith('http')) {
      imageProvider = FileImage(File(agent.avatar));
    } else {
      imageProvider = NetworkImage(agent.avatar);
    }
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: Image(
          image: imageProvider,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => CircleAvatar(
            radius: size / 2,
            child: Text(
              agent.name.isNotEmpty ? agent.name[0].toUpperCase() : '?',
              style: TextStyle(fontSize: fontSize * 0.6),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: Navigator.canPop(context),
        title: Text(l10n.createGroup_title),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: _createGroup,
              icon: const Icon(Icons.check, size: 18),
              label: Text(l10n.createGroup_create),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Theme.of(context).primaryColor,
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 群名输入
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      controller: _nameController,
                      decoration: InputDecoration(
                        labelText: l10n.createGroup_groupName,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.group),
                      ),
                    ),
                  ),

                  // 群聊目的/描述
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _purposeController,
                      maxLines: 2,
                      decoration: InputDecoration(
                        labelText: l10n.createGroup_purpose,
                        hintText: l10n.createGroup_purposeHint,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.description),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // 系统提示词
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _systemPromptController,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: l10n.createGroup_systemPrompt,
                        hintText: l10n.createGroup_systemPromptHint,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.psychology),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // 最大编排轮次
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _maxRoundsController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: l10n.createGroup_maxLoopRounds,
                        hintText: l10n.createGroup_maxLoopRoundsHint,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.loop),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // 提及模式
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: DropdownButtonFormField<String>(
                      value: _mentionMode,
                      decoration: InputDecoration(
                        labelText: l10n.createGroup_mentionMode,
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
                          setState(() { _mentionMode = value; });
                        }
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 20, top: 4, right: 16),
                    child: Text(
                      _mentionMode == 'allMembers'
                          ? l10n.chat_mentionModeAllMembersDesc
                          : l10n.chat_mentionModeAdminOnlyDesc,
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ),

                  const SizedBox(height: 4),

                  // 计划模式（Flow 模式开启时禁用，两者互斥，Flow 优先）
                  SwitchListTile(
                    title: Text(l10n.chat_planningMode),
                    subtitle: Text(
                      l10n.chat_planningModeDesc,
                      style: const TextStyle(fontSize: 12),
                    ),
                    secondary: const Icon(Icons.assignment_turned_in_outlined),
                    value: _planningMode,
                    onChanged: _flowMode ? null : (v) => setState(() => _planningMode = v),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  ),

                  // Flow 模式
                  SwitchListTile(
                    title: Text(l10n.chat_flowMode),
                    subtitle: Text(
                      l10n.chat_flowModeDesc,
                      style: const TextStyle(fontSize: 12),
                    ),
                    secondary: const Icon(Icons.account_tree_outlined),
                    value: _flowMode,
                    onChanged: (v) => setState(() => _flowMode = v),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  ),

                  const SizedBox(height: 8),

                  // 已选择的 Agents
                  if (_selectedAgentIds.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      height: 60,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: _selectedAgentIds.length,
                        itemBuilder: (context, index) {
                          final agentId = _selectedAgentIds.elementAt(index);
                          final agent = _agents.firstWhere((a) => a.id == agentId);

                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Chip(
                              avatar: _buildAgentAvatar(agent, size: 24, fontSize: 16),
                              label: Text(agent.name),
                              onDeleted: () {
                                setState(() {
                                  _selectedAgentIds.remove(agentId);
                                  _groupBioControllers[agentId]?.dispose();
                                  _groupBioControllers.remove(agentId);
                                  if (_adminAgentId == agentId) {
                                    _adminAgentId = _selectedAgentIds.isNotEmpty
                                        ? _selectedAgentIds.first
                                        : null;
                                  }
                                });
                              },
                            ),
                          );
                        },
                      ),
                    ),

                  const Divider(),

                  // Agent 列表
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Text(
                          l10n.createGroup_selectAgent,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          l10n.createGroup_agentCount(_selectedAgentIds.length, _agents.length),
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),

                  if (_agents.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(l10n.createGroup_noAgents),
                      ),
                    )
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _agents.length,
                      itemBuilder: (context, index) {
                        final agent = _agents[index];
                        final isSelected = _selectedAgentIds.contains(agent.id);

                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: _buildAgentAvatar(agent),
                              trailing: Checkbox(
                                value: isSelected,
                                onChanged: (checked) {
                                  setState(() {
                                    if (checked == true) {
                                      _selectedAgentIds.add(agent.id);
                                      _groupBioControllers[agent.id] = TextEditingController();
                                      _adminAgentId ??= agent.id;
                                    } else {
                                      _selectedAgentIds.remove(agent.id);
                                      _groupBioControllers[agent.id]?.dispose();
                                      _groupBioControllers.remove(agent.id);
                                      if (_adminAgentId == agent.id) {
                                        _adminAgentId = _selectedAgentIds.isNotEmpty
                                            ? _selectedAgentIds.first
                                            : null;
                                      }
                                    }
                                  });
                                },
                              ),
                              onTap: () {
                                setState(() {
                                  if (isSelected) {
                                    _selectedAgentIds.remove(agent.id);
                                    _groupBioControllers[agent.id]?.dispose();
                                    _groupBioControllers.remove(agent.id);
                                    if (_adminAgentId == agent.id) {
                                      _adminAgentId = _selectedAgentIds.isNotEmpty
                                          ? _selectedAgentIds.first
                                          : null;
                                    }
                                  } else {
                                    _selectedAgentIds.add(agent.id);
                                    _groupBioControllers[agent.id] = TextEditingController();
                                    _adminAgentId ??= agent.id;
                                  }
                                });
                              },
                              title: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      agent.name,
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (isSelected && _adminAgentId == agent.id) ...[
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
                              ),
                              subtitle: Row(
                                children: [
                                  Expanded(child: Text(agent.provider.name)),
                                  if (isSelected && _adminAgentId != agent.id)
                                    GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          _adminAgentId = agent.id;
                                        });
                                      },
                                      child: Text(
                                        l10n.createGroup_setAsAdmin,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.orange[700],
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (isSelected)
                              Padding(
                                padding: const EdgeInsets.only(left: 56, right: 16, bottom: 8),
                                child: TextField(
                                  controller: _groupBioControllers[agent.id],
                                  maxLines: 2,
                                  decoration: InputDecoration(
                                    labelText: l10n.createGroup_groupRole,
                                    hintText: l10n.createGroup_groupRoleHint,
                                    border: const OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),

                  // 底部提交按钮
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: _selectedAgentIds.isEmpty ? null : _createGroup,
                        child: Text(
                          l10n.createGroup_button,
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
