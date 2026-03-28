import 'package:flutter/material.dart';
import '../models/remote_agent.dart';
import '../services/remote_agent_service.dart';
import '../services/local_database_service.dart';
import '../services/token_service.dart';
import '../services/agent_memory_biz_service.dart';
import '../services/logger_service.dart';
import 'agent_memory_detail_screen.dart';

/// Agent 记忆管理列表页面（新版本）
/// 
/// 显示所有 Remote Agent 的列表，用户可以点击每个 Agent 查看和管理其记忆。
/// 支持 pull-to-refresh 实时更新记忆计数。
class AgentMemoryManagementScreen extends StatefulWidget {
  const AgentMemoryManagementScreen({Key? key}) : super(key: key);

  @override
  State<AgentMemoryManagementScreen> createState() =>
      _AgentMemoryManagementScreenState();
}

class _AgentMemoryManagementScreenState
    extends State<AgentMemoryManagementScreen> {
  late RemoteAgentService _agentService;
  final AgentMemoryBizService _memoryService = AgentMemoryBizService();
  
  List<RemoteAgent> _agents = [];
  Map<String, int> _memoryCounts = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    final dbService = LocalDatabaseService();
    final tokenService = TokenService(dbService);
    _agentService = RemoteAgentService(dbService, tokenService);
    _loadAgents();
  }

  Future<void> _loadAgents() async {
    try {
      final agents = await _agentService.getAllAgents();
      setState(() {
        _agents = agents;
        _isLoading = false;
      });

      // 加载每个 Agent 的记忆数量
      _loadMemoryCounts();
    } catch (e) {
      LoggerService().error(
        'Failed to load agents',
        tag: 'AgentMemoryManagement',
        error: e,
      );
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load agents')),
        );
      }
    }
  }

  Future<void> _loadMemoryCounts() async {
    for (final agent in _agents) {
      try {
        final count = await _memoryService.getMemoryCount(agent.id);
        if (mounted) {
          setState(() {
            _memoryCounts[agent.id] = count;
          });
        }
      } catch (e) {
        LoggerService().error(
          'Failed to load memory count for ${agent.id}',
          tag: 'AgentMemoryManagement',
          error: e,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Agent Memories'),
          centerTitle: true,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_agents.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Agent Memories'),
          centerTitle: true,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.psychology,
                size: 64,
                color: Colors.grey[400],
              ),
              const SizedBox(height: 16),
              Text(
                'No Agents Available',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Add agents to manage their memories',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[500],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent Memories'),
        centerTitle: true,
      ),
      body: RefreshIndicator(
        onRefresh: _loadAgents,
        child: ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: _agents.length,
          itemBuilder: (context, index) {
            final agent = _agents[index];
            final count = _memoryCounts[agent.id] ?? 0;
            return _buildAgentCard(agent, count);
          },
        ),
      ),
    );
  }

  Widget _buildAgentCard(RemoteAgent agent, int memoryCount) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          child: Text(agent.avatar),
        ),
        title: Text(agent.name),
        subtitle: Text(
          agent.bio ?? 'No description',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Badge.count(
              count: memoryCount,
              backgroundColor: Colors.blue,
              textColor: Colors.white,
            ),
            const SizedBox(height: 4),
            Text(
              'memory',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AgentMemoryDetailScreen(agent: agent),
            ),
          ).then((_) {
            // 返回时刷新计数
            _loadMemoryCounts();
          });
        },
      ),
    );
  }
}
