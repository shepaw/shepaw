import 'package:flutter/material.dart';
import '../models/remote_agent.dart';
import '../models/agent_memory.dart';
import '../services/agent_memory_service.dart';
import '../services/logger_service.dart';

/// Agent 记忆详情页面
/// 
/// 显示指定 Agent 的所有记忆，支持：
/// - 结构化视图（按 key 展示）
/// - 时间线视图（按时间展示）
/// - 添加、编辑、删除记忆
/// - 导出为 JSON/Markdown
class AgentMemoryDetailScreen extends StatefulWidget {
  final RemoteAgent agent;

  const AgentMemoryDetailScreen({
    Key? key,
    required this.agent,
  }) : super(key: key);

  @override
  State<AgentMemoryDetailScreen> createState() =>
      _AgentMemoryDetailScreenState();
}

class _AgentMemoryDetailScreenState extends State<AgentMemoryDetailScreen>
    with SingleTickerProviderStateMixin {
  final AgentMemoryService _memoryService = AgentMemoryService.instance;
  late TabController _tabController;

  List<AgentMemory> _memories = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadMemories();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadMemories() async {
    try {
      final memories = await _memoryService.getAgentMemories(widget.agent.id);
      if (mounted) {
        setState(() {
          _memories = memories;
          _isLoading = false;
        });
      }
    } catch (e) {
      LoggerService().error(
        'Failed to load memories',
        tag: 'AgentMemoryDetail',
        error: e,
      );
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load memories')),
        );
      }
    }
  }

  Future<void> _addNote() async {
    final noteController = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Memory Note'),
        content: TextField(
          controller: noteController,
          minLines: 3,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'Enter memory note...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, noteController.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (result != null && result.trim().isNotEmpty) {
      try {
        await _memoryService.appendNote(widget.agent.id, result);
        await _loadMemories();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Note added')),
          );
        }
      } catch (e) {
        LoggerService().error(
          'Failed to add note',
          tag: 'AgentMemoryDetail',
          error: e,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to add note')),
          );
        }
      }
    }

    noteController.dispose();
  }

  Future<void> _deleteMemory(String key) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Memory'),
        content: Text('Delete "$key"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _memoryService.deleteNote(widget.agent.id, key);
      await _loadMemories();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Memory deleted')),
        );
      }
    } catch (e) {
      LoggerService().error(
        'Failed to delete memory',
        tag: 'AgentMemoryDetail',
        error: e,
      );
    }
  }

  Future<void> _clearAllMemories() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All Memories'),
        content: const Text(
          'This will delete all memories for this agent. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _memoryService.clearAllMemories(widget.agent.id);
      await _loadMemories();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All memories cleared')),
        );
      }
    } catch (e) {
      LoggerService().error(
        'Failed to clear memories',
        tag: 'AgentMemoryDetail',
        error: e,
      );
    }
  }

  Future<void> _exportMemories(String format) async {
    try {
      final content = format == 'json'
          ? await _memoryService.exportAsJson(widget.agent.id)
          : await _memoryService.exportAsMarkdown(widget.agent.id);

      if (mounted) {
        // 显示导出内容（可根据需要保存到文件）
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Export as $format'),
            content: SingleChildScrollView(
              child: SelectableText(content),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      LoggerService().error(
        'Failed to export memories',
        tag: 'AgentMemoryDetail',
        error: e,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to export')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.agent.name} Memories'),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.view_list), text: 'Structured'),
            Tab(icon: Icon(Icons.timeline), text: 'Timeline'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildStructuredView(),
                _buildTimelineView(),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addNote,
        tooltip: 'Add Note',
        child: const Icon(Icons.add),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Colors.grey[300]!)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton.icon(
              onPressed: () => _exportMemories('json'),
              icon: const Icon(Icons.download),
              label: const Text('JSON'),
            ),
            TextButton.icon(
              onPressed: () => _exportMemories('markdown'),
              icon: const Icon(Icons.download),
              label: const Text('Markdown'),
            ),
            TextButton.icon(
              onPressed: _clearAllMemories,
              icon: const Icon(Icons.delete_forever, color: Colors.red),
              label: const Text('Clear All'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStructuredView() {
    if (_memories.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.memory, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No Memories Yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Add notes to store memories',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[500],
                  ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _memories.length,
      itemBuilder: (context, index) {
        final memory = _memories[index];
        return Card(
          child: ListTile(
            title: Text(memory.key),
            subtitle: Text(
              memory.value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: () => _deleteMemory(memory.key),
            ),
            onTap: () => _showMemoryDetail(memory),
          ),
        );
      },
    );
  }

  Widget _buildTimelineView() {
    if (_memories.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.schedule, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No Timeline Events',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _memories.length,
      itemBuilder: (context, index) {
        final memory = _memories[index];
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        memory.key,
                        style: Theme.of(context).textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      memory.createdAtFormatted,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey[600],
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  memory.value,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () => _showMemoryDetail(memory),
                      icon: const Icon(Icons.visibility),
                      label: const Text('View'),
                    ),
                    TextButton.icon(
                      onPressed: () => _deleteMemory(memory.key),
                      icon: const Icon(Icons.delete, color: Colors.red),
                      label: const Text('Delete'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showMemoryDetail(AgentMemory memory) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(memory.key),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Created: ${memory.createdAtFormatted}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),
              const SizedBox(height: 12),
              SelectableText(memory.value),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
