import 'package:flutter/material.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../services/local_api_service.dart';
import '../services/logger_service.dart';
import '../utils/exceptions.dart';
import '../widgets/avatar_image.dart';
import 'agent_detail_screen.dart';
import 'add_remote_agent_screen.dart';
import 'chat_screen.dart';
import '../utils/layout_utils.dart';
import '../l10n/app_localizations.dart';

/// Agent 列表页面
class AgentListScreen extends StatefulWidget {
  const AgentListScreen({Key? key}) : super(key: key);

  @override
  State<AgentListScreen> createState() => _AgentListScreenState();
}

class _AgentListScreenState extends State<AgentListScreen> {
  final LocalApiService _apiService = LocalApiService();
  List<Agent> _agents = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadAgents();
  }

  /// 加载 Agent 列表
  Future<void> _loadAgents() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final agents = await _apiService.getAgents();
      setState(() {
        _agents = agents;
        _isLoading = false;
      });
      LoggerService().info('加载了 ${agents.length} 个 Agent', tag: 'AgentList');
    } catch (e) {
      LoggerService().error(l10n.agentList_loadFailed, tag: 'AgentList', error: e);
      setState(() {
        _errorMessage = ExceptionHandler.getUserMessage(e);
        _isLoading = false;
      });
    }
  }

  /// 删除 Agent
  Future<void> _deleteAgent(Agent agent) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext);
        return AlertDialog(
          title: Text(l10n.agentDetail_confirmDelete),
          content: Text(l10n.agentList_deleteConfirm(agent.name)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.common_cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text(l10n.common_delete),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    final l10n = AppLocalizations.of(context);
    try {
      await _apiService.deleteAgent(agent.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.agentList_deleted(agent.name))),
      );
      _loadAgents(); // 刷新列表
    } catch (e) {
      LoggerService().error(l10n.agentList_deleteFailed, tag: 'AgentList', error: e);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ExceptionHandler.getUserMessage(e)),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.agentList_title),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadAgents,
            tooltip: l10n.common_refresh,
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddAgentMenu(),
        child: const Icon(Icons.add),
        tooltip: l10n.home_addAgent,
      ),
    );
  }

  Widget _buildBody() {
    final l10n = AppLocalizations.of(context);
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: Colors.red[300],
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: TextStyle(color: Colors.red[700]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _loadAgents,
              icon: const Icon(Icons.refresh),
              label: Text(l10n.common_retry),
            ),
          ],
        ),
      );
    }

    if (_agents.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: 100,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 24),
            Text(
              l10n.home_noAgents,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.agentList_emptyHint,
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadAgents,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _agents.length,
        itemBuilder: (context, index) {
          final agent = _agents[index];
          return _buildAgentCard(agent);
        },
      ),
    );
  }

  Widget _buildAgentCard(Agent agent) {
    final l10n = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _navigateToAgentDetail(agent),
        borderRadius: BorderRadius.circular(12),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  // Avatar
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: _getStatusColor(agent.status).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    alignment: Alignment.center,
                    child: agent.avatar.isNotEmpty
                        ? AvatarImage(
                            avatar: agent.avatar,
                            size: 60,
                            borderRadius: 15,
                            fallback: Icon(
                              Icons.smart_toy,
                              size: 30,
                              color: _getStatusColor(agent.status),
                            ),
                          )
                        : Icon(
                            Icons.smart_toy,
                            size: 30,
                            color: _getStatusColor(agent.status),
                          ),
                  ),
                  const SizedBox(width: 16),

                  // Agent 信息
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                agent.name,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            _buildStatusChip(agent.status),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'ID: ${agent.id}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.agentList_typeLabel(agent.type ?? ''),
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[700],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 操作按钮
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (value) {
                      switch (value) {
                        case 'chat':
                          _startConversation(agent);
                          break;
                        case 'edit':
                          _navigateToAgentDetailForEdit(agent);
                          break;
                        case 'detail':
                          _navigateToAgentDetail(agent);
                          break;
                        case 'delete':
                          _deleteAgent(agent);
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'chat',
                        child: Row(
                          children: [
                            Icon(Icons.chat),
                            SizedBox(width: 8),
                            Text(l10n.agentDetail_startConversation),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'edit',
                        child: Row(
                          children: [
                            Icon(Icons.edit_outlined),
                            SizedBox(width: 8),
                            Text(l10n.common_edit),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'detail',
                        child: Row(
                          children: [
                            Icon(Icons.info_outline),
                            SizedBox(width: 8),
                            Text(l10n.chat_viewDetails),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline, color: Colors.red),
                            SizedBox(width: 8),
                            Text(l10n.common_delete, style: TextStyle(color: Colors.red)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // 快捷操作按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _startConversation(agent),
                      icon: const Icon(Icons.chat, size: 18),
                      label: Text(l10n.agentDetail_startConversation),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _navigateToAgentDetail(agent),
                      icon: const Icon(Icons.info_outline, size: 18),
                      label: Text(l10n.widget_details),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(AgentStatus status) {
    final color = _getStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        _getStatusText(status),
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Color _getStatusColor(AgentStatus status) {
    switch (status.state.toLowerCase()) {
      case 'online':
      case 'active':
        return Colors.green;
      case 'offline':
        return Colors.grey;
      case 'busy':
        return Colors.orange;
      case 'error':
        return Colors.red;
      default:
        return Colors.blue;
    }
  }

  String _getStatusText(AgentStatus status) {
    final l10n = AppLocalizations.of(context);    switch (status.state.toLowerCase()) {
      case 'online':
      case 'active':
        return l10n.home_statusOnline;
      case 'offline':
        return l10n.home_statusOffline;
      case 'busy':
        return l10n.common_busy;
      case 'error':
        return l10n.status_error;
      default:
        return status.state;
    }
  }

  void _navigateToAgentDetail(Agent agent) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AgentDetailScreen(agent: agent),
      ),
    ).then((_) => _loadAgents()); // 返回后刷新
  }

  /// 直接以编辑模式打开 Agent 详情页
  void _navigateToAgentDetailForEdit(Agent agent) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AgentDetailScreen(agent: agent, initialEditMode: true),
      ),
    ).then((_) => _loadAgents()); // 返回后刷新
  }

  void _navigateToAddAgent() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const AgentDetailScreen(),
      ),
    ).then((_) => _loadAgents()); // 返回后刷新
  }

  void _showAddAgentMenu() {
    final l10n = AppLocalizations.of(context);
    LayoutUtils.showAdaptivePanel(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              l10n.agentList_selectType,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Text('🦅', style: TextStyle(fontSize: 32)),
            title: const Text('OpenClaw Agent'),
            subtitle: Text(l10n.agentList_typeOpenClaw),
            onTap: () {
              Navigator.pop(context);
              _navigateToAddOpenClawAgent();
            },
          ),
          ListTile(
            leading: const Text('🤖', style: TextStyle(fontSize: 32)),
            title: const Text('A2A Agent'),
            subtitle: Text(l10n.agentList_typeA2a),
            onTap: () {
              Navigator.pop(context);
              _navigateToAddAgent();
            },
          ),
          ListTile(
            leading: const Text('🔗', style: TextStyle(fontSize: 32)),
            title: Text(l10n.agentList_typeCustom),
            subtitle: Text(l10n.agentList_typeCustomDesc),
            onTap: () {
              Navigator.pop(context);
              _navigateToAddAgent();
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  void _navigateToAddOpenClawAgent() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const AddRemoteAgentScreen(),
      ),
    ).then((_) => _loadAgents()); // 返回后刷新
  }

  /// 发起与 Agent 的对话
  Future<void> _startConversation(Agent agent) async {
    final l10n = AppLocalizations.of(context);
    try {
      // 尝试查找已存在的 DM 频道
      final channels = await _apiService.getChannels();
      Channel? existingDM;

      for (final channel in channels) {
        if (channel.isDM &&
            channel.members.length == 1 &&
            channel.members[0].id == agent.id) {
          existingDM = channel;
          break;
        }
      }

      // 如果不存在，创建新的 DM 频道
      if (existingDM == null) {
        final dmChannel = Channel(
          id: '', // 服务器会生成
          name: agent.name,
          type: 'dm',
          members: [
            ChannelMember(
              id: agent.id,
              type: 'agent',
              role: 'member',
              joinedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          ],
          avatar: agent.avatar,
          description: l10n.agentList_conversationWith(agent.name),
        );

        existingDM = await _apiService.createChannel(dmChannel);
        LoggerService().info('创建了与 ${agent.name} 的 DM 频道: ${existingDM.id}', tag: 'AgentList');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.agentList_conversationCreated(agent.name))),
          );
        }
      }

      // 导航到聊天页面
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const ChatScreen(),
          ),
        );
      }
    } catch (e) {
      LoggerService().error(l10n.agentList_createConversationFailed, tag: 'AgentList', error: e);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.agentList_createConversationFailedDetail(ExceptionHandler.getUserMessage(e))),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _apiService.dispose();
    super.dispose();
  }
}
