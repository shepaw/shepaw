import 'package:flutter/material.dart';
import '../models/remote_agent.dart';
import '../services/remote_agent_service.dart';
import '../service_locator.dart' show getIt;
import '../services/agent_memory_biz_service.dart';
import '../services/logger_service.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_image.dart';
import 'agent_memory_detail_screen.dart';

/// Agent 记忆管理列表：按 Agent 查看结构化记忆。
///
/// 产品入口在各 Agent 详情的「记忆」项；
/// 本页可作为全量总览单独打开。
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
    _agentService = getIt<RemoteAgentService>();
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
        leading: AvatarImage(
          avatar: agent.avatar.isNotEmpty ? agent.avatar : '🤖',
          size: 40,
          borderRadius: 20,
          fallback: Text(
            agent.name.isNotEmpty ? agent.name[0] : '?',
            style: const TextStyle(fontSize: 18),
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
          children: [
            Badge.count(
              count: memoryCount,
              backgroundColor: AppColors.primary,
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
