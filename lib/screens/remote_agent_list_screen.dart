import 'package:flutter/material.dart';
import '../models/remote_agent.dart';
import '../services/remote_agent_service.dart';
import '../service_locator.dart' show getIt;
import '../services/logger_service.dart';
import 'add_remote_agent_screen.dart';
import 'agent_token_display_screen.dart';

/// 远端助手列表界面
class RemoteAgentListScreen extends StatefulWidget {
  const RemoteAgentListScreen({super.key});

  @override
  State<RemoteAgentListScreen> createState() => _RemoteAgentListScreenState();
}

class _RemoteAgentListScreenState extends State<RemoteAgentListScreen> {
  late RemoteAgentService _agentService;
  List<RemoteAgent> _agents = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _agentService = getIt<RemoteAgentService>();

    // 先加载数据显示
    _loadAgents();

    // 然后执行健康检查以更新状态
    _loadAgentsWithHealthCheck();
  }

  /// 加载 Agent 列表并执行健康检查
  Future<void> _loadAgentsWithHealthCheck() async {
    try {
      // 执行健康检查
      await _agentService.checkAllAgentsHealth(
        timeout: const Duration(seconds: 3),
      );

      // 重新加载 Agent 列表以获取更新后的状态
      await _loadAgents();
    } catch (e) {
      LoggerService().error('Health check failed', tag: 'AgentList', error: e);
      // 即使健康检查失败，也保留已加载的数据
    }
  }

  Future<void> _loadAgents() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final agents = await _agentService.getAllAgents();
      setState(() {
        _agents = agents;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: $e')),
        );
      }
    }
  }

  /// 检查所有 Agent 的健康状态
  Future<void> _checkAgentHealth() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // 显示健康检查提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                SizedBox(width: 12),
                Text('正在检查 Agent 健康状态...'),
              ],
            ),
            duration: Duration(seconds: 3),
          ),
        );
      }

      // 检查所有 Agent 的健康状态
      await _agentService.checkAllAgentsHealth(
        timeout: const Duration(seconds: 5),
      );

      // 重新加载 Agent 列表以更新状态
      await _loadAgents();

      // 显示结果
      if (mounted) {
        final onlineCount = _agents.where((a) => a.isOnline).length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('健康检查完成，在线: $onlineCount/${_agents.length}'),
            backgroundColor: onlineCount == _agents.length 
                ? Colors.green 
                : Colors.orange,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('健康检查失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteAgent(RemoteAgent agent) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除助手 "${agent.name}" 吗？\n\n'
            '删除后，远端助手将无法再使用此 Token 连接。'),
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
      await _agentService.deleteAgent(agent.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除 ${agent.name}')),
        );
      }
      _loadAgents();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('删除失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showAgentDetails(RemoteAgent agent) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AgentTokenDisplayScreen(agent: agent),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('远端助手'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.health_and_safety),
            onPressed: _checkAgentHealth,
            tooltip: '检查健康状态',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadAgents,
            tooltip: '刷新',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _agents.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _loadAgents,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: _agents.length,
                    itemBuilder: (context, index) {
                      final agent = _agents[index];
                      return _buildAgentCard(agent);
                    },
                  ),
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToAddAgent,
        icon: const Icon(Icons.add),
        label: const Text('添加助手'),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off,
            size: 80,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            '还没有远端助手',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.grey[600],
                ),
          ),
          const SizedBox(height: 8),
          Text(
            '点击下方按钮添加第一个助手',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[500],
                ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _navigateToAddAgent,
            icon: const Icon(Icons.add),
            label: const Text('添加助手'),
          ),
        ],
      ),
    );
  }

  Widget _buildAgentCard(RemoteAgent agent) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: InkWell(
        onTap: () => _showAgentDetails(agent),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  // 头像
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        agent.avatar,
                        style: const TextStyle(fontSize: 24),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // 信息
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
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            // 状态指示器
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: _getStatusColor(agent.status).withOpacity(0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    agent.statusIcon,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    agent.statusText,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: _getStatusColor(agent.status),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (agent.bio != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            agent.bio!,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            _buildInfoChip(
                              agent.protocolName,
                              Icons.settings_ethernet,
                            ),
                            const SizedBox(width: 8),
                            _buildInfoChip(
                              agent.connectionTypeName,
                              Icons.link,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // 操作按钮
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'view') {
                        _showAgentDetails(agent);
                      } else if (value == 'delete') {
                        _deleteAgent(agent);
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'view',
                        child: Row(
                          children: [
                            Icon(Icons.visibility, size: 20),
                            SizedBox(width: 8),
                            Text('查看 Token'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete, size: 20, color: Colors.red),
                            SizedBox(width: 8),
                            Text('删除', style: TextStyle(color: Colors.red)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (agent.lastHeartbeat != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 12,
                        color: Colors.grey[600],
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '最后活跃: ${_formatLastHeartbeat(agent.lastHeartbeat!)}',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoChip(String label, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: Colors.grey[700]),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: Colors.grey[700],
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(AgentStatus status) {
    switch (status) {
      case AgentStatus.online:
        return Colors.green;
      case AgentStatus.offline:
        return Colors.orange;
      case AgentStatus.error:
        return Colors.red;
    }
  }

  String _formatLastHeartbeat(int timestampMs) {
    final now = DateTime.now();
    final time = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final diff = now.difference(time);

    if (diff.inMinutes < 1) {
      return '刚刚';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes} 分钟前';
    } else if (diff.inHours < 24) {
      return '${diff.inHours} 小时前';
    } else {
      return '${diff.inDays} 天前';
    }
  }

  void _navigateToAddAgent() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const AddRemoteAgentScreen(),
      ),
    ).then((_) => _loadAgents());
  }
}
