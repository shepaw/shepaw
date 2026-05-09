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
      LoggerService().error('加载 Agent 列表失败', tag: 'AgentList', error: e);
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
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除 Agent "${agent.name}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _apiService.deleteAgent(agent.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除 ${agent.name}')),
      );
      _loadAgents(); // 刷新列表
    } catch (e) {
      LoggerService().error('删除 Agent 失败', tag: 'AgentList', error: e);
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent 管理'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadAgents,
            tooltip: '刷新',
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddAgentMenu(),
        child: const Icon(Icons.add),
        tooltip: '添加 Agent',
      ),
    );
  }

  Widget _buildBody() {
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
              label: const Text('重试'),
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
              '暂无 Agent',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '点击下方按钮添加您的第一个 Agent',
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
                          '类型: ${agent.type}',
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
                      const PopupMenuItem(
                        value: 'chat',
                        child: Row(
                          children: [
                            Icon(Icons.chat),
                            SizedBox(width: 8),
                            Text('发起对话'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'edit',
                        child: Row(
                          children: [
                            Icon(Icons.edit_outlined),
                            SizedBox(width: 8),
                            Text('编辑'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'detail',
                        child: Row(
                          children: [
                            Icon(Icons.info_outline),
                            SizedBox(width: 8),
                            Text('查看详情'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline, color: Colors.red),
                            SizedBox(width: 8),
                            Text('删除', style: TextStyle(color: Colors.red)),
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
                      label: const Text('发起对话'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _navigateToAgentDetail(agent),
                      icon: const Icon(Icons.info_outline, size: 18),
                      label: const Text('详情'),
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
    switch (status.state.toLowerCase()) {
      case 'online':
      case 'active':
        return '在线';
      case 'offline':
        return '离线';
      case 'busy':
        return '忙碌';
      case 'error':
        return '错误';
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
    LayoutUtils.showAdaptivePanel(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: const Text(
              '选择 Agent 类型',
              style: TextStyle(
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
            subtitle: const Text('通过 ACP 协议连接 OpenClaw Gateway'),
            onTap: () {
              Navigator.pop(context);
              _navigateToAddOpenClawAgent();
            },
          ),
          ListTile(
            leading: const Text('🤖', style: TextStyle(fontSize: 32)),
            title: const Text('A2A Agent'),
            subtitle: const Text('支持 A2A 协议的通用 Agent'),
            onTap: () {
              Navigator.pop(context);
              _navigateToAddAgent();
            },
          ),
          ListTile(
            leading: const Text('🔗', style: TextStyle(fontSize: 32)),
            title: const Text('自定义 Agent'),
            subtitle: const Text('手动配置的其他类型 Agent'),
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
          description: '与 ${agent.name} 的对话',
        );

        existingDM = await _apiService.createChannel(dmChannel);
        LoggerService().info('创建了与 ${agent.name} 的 DM 频道: ${existingDM.id}', tag: 'AgentList');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已创建与 ${agent.name} 的对话')),
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
      LoggerService().error('创建对话失败', tag: 'AgentList', error: e);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('创建对话失败: ${ExceptionHandler.getUserMessage(e)}'),
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
