import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n_helpers.dart';
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
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.remoteAgent_loadFailed('$e'))),
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
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                const SizedBox(width: 12),
                Text(l10n.remoteAgent_checkingHealth),
              ],
            ),
            duration: const Duration(seconds: 3),
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
        final l10n = AppLocalizations.of(context);
    final onlineCount = _agents.where((a) => a.isOnline).length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.remoteAgent_healthDone(onlineCount, _agents.length),
            ),
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
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.remoteAgent_healthFailed('$e')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteAgent(RemoteAgent agent) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext);
        return AlertDialog(
          title: Text(l10n.agentDetail_confirmDelete),
          content: Text(l10n.remoteAgent_deleteConfirm(agent.name)),
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

    try {
      await _agentService.deleteAgent(agent.id);
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.remoteAgent_deleted(agent.name))),
        );
      }
      _loadAgents();
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.remoteAgent_deleteFailed('$e')),
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
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.remoteAgent_title),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.health_and_safety),
            onPressed: _checkAgentHealth,
            tooltip: l10n.remoteAgent_checkHealth,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadAgents,
            tooltip: l10n.common_refresh,
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
        label: Text(l10n.remoteAgent_add),
      ),
    );
  }

  Widget _buildEmptyState() {
    final l10n = AppLocalizations.of(context);
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
            l10n.remoteAgent_empty,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.grey[600],
                ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.remoteAgent_emptyHint,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[500],
                ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _navigateToAddAgent,
            icon: const Icon(Icons.add),
            label: Text(l10n.remoteAgent_add),
          ),
        ],
      ),
    );
  }

  Widget _buildAgentCard(RemoteAgent agent) {
    final l10n = AppLocalizations.of(context);
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
                                    agent.localizedStatusText(l10n),
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
                              agent.localizedProtocolName(l10n),
                              Icons.settings_ethernet,
                            ),
                            const SizedBox(width: 8),
                            _buildInfoChip(
                              agent.localizedConnectionTypeName(l10n),
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
                      PopupMenuItem(
                        value: 'view',
                        child: Row(
                          children: [
                            Icon(Icons.visibility, size: 20),
                            SizedBox(width: 8),
                            Text(l10n.remoteAgent_viewToken),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete, size: 20, color: Colors.red),
                            SizedBox(width: 8),
                            Text(l10n.common_delete, style: TextStyle(color: Colors.red)),
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
                        l10n.remoteAgent_lastActive(
                          _formatLastHeartbeat(l10n, agent.lastHeartbeat!),
                        ),
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

  String _formatLastHeartbeat(AppLocalizations l10n, int timestampMs) {
    final now = DateTime.now();
    final time = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final diff = now.difference(time);

    if (diff.inMinutes < 1) {
      return l10n.agentDetail_justNow;
    } else if (diff.inMinutes < 60) {
      return l10n.agentDetail_minutesAgo(diff.inMinutes);
    } else if (diff.inHours < 24) {
      return l10n.agentDetail_hoursAgo(diff.inHours);
    } else {
      return l10n.common_daysAgo(diff.inDays);
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
