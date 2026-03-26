import 'package:flutter/material.dart';
import '../models/remote_agent.dart';
import '../services/remote_agent_service.dart';
import '../services/local_database_service.dart';
import '../services/token_service.dart';
import '../services/agent_memory_service.dart';
import '../services/logger_service.dart';
import 'agent_memory_detail_screen.dart';

/// Agent 记忆管理列表页面
/// 
/// 显示所有 Remote Agent 的列表，用户可以点击每个 Agent 查看和管理其记忆。
class AgentMemoryManagementScreen extends StatefulWidget {
  const AgentMemoryManagementScreen({Key? key}) : super(key: key);

  @override
  State<AgentMemoryManagementScreen> createState() =>
      _AgentMemoryManagementScreenState();
}

class _AgentMemoryManagementScreenState
    extends State<AgentMemoryManagementScreen> {
  late RemoteAgentService _agentService;
  final AgentMemoryService _memoryService = AgentMemoryService.instance;
  
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
        onRefresh: () async {
          await _loadAgents();
        },
        child: ListView.builder(
          itemCount: _agents.length,
          itemBuilder: (context, index) {
            final agent = _agents[index];
            final memoryCount = _memoryCounts[agent.id] ?? 0;

            return _buildAgentTile(agent, memoryCount, context);
          },
        ),
      ),
    );
  }

  Widget _buildAgentTile(
    RemoteAgent agent,
    int memoryCount,
    BuildContext context,
  ) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Colors.blue[100],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              agent.avatar,
              style: const TextStyle(fontSize: 24),
            ),
          ),
        ),
        title: Text(agent.name),
        subtitle: Text(
          agent.bio ?? 'No description',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: memoryCount > 0 ? Colors.green[100] : Colors.grey[200],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$memoryCount',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: memoryCount > 0 ? Colors.green[800] : Colors.grey[600],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'memories',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
          ],
        ),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  AgentMemoryDetailScreen(agent: agent),
            ),
          ).then((_) {
            // 返回时刷新数据
            _loadMemoryCounts();
          });
        },
      ),
    );
  }
}
