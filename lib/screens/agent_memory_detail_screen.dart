import 'package:flutter/material.dart';
import '../models/remote_agent.dart';
import '../models/agent_memory_entry.dart';
import '../services/agent_memory_biz_service.dart';
import '../services/logger_service.dart';

/// Agent 记忆详情页面（新版本）
/// 
/// 显示指定 Agent 的所有记忆，支持：
/// - 结构化视图（按类型和来源展示）
/// - 时间线视图（按时间展示）
/// - 添加、删除记忆，支持类型/关键词/来源设置
/// - 导出为 JSON/Markdown
/// - 关键词搜索
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
  final AgentMemoryBizService _memoryService = AgentMemoryBizService();
  late TabController _tabController;

  List<AgentMemoryEntry> _memories = [];
  bool _isLoading = true;
  String? _filterKeyword;
  MemoryType? _filterType;

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

  Future<void> _loadMemories({String? keyword, MemoryType? type}) async {
    try {
      final memories = keyword != null && keyword.isNotEmpty
          ? await _memoryService.queryByKeyword(widget.agent.id, keyword)
          : await _memoryService.getAllMemories(widget.agent.id, type: type);
      
      if (mounted) {
        setState(() {
          _memories = memories;
          _isLoading = false;
          _filterKeyword = keyword;
          _filterType = type;
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

  Future<void> _addMemory() async {
    final contentController = TextEditingController();
    MemoryType selectedType = MemoryType.conversation;
    final keywordsController = TextEditingController();

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add New Memory'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Content
                const Text('Content'),
                const SizedBox(height: 8),
                TextField(
                  controller: contentController,
                  minLines: 3,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    hintText: 'Enter memory content...',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                
                // Type
                const Text('Type'),
                const SizedBox(height: 8),
                DropdownButton<MemoryType>(
                  value: selectedType,
                  isExpanded: true,
                  items: MemoryType.values.map((type) {
                    return DropdownMenuItem(
                      value: type,
                      child: Text(type.displayName),
                    );
                  }).toList(),
                  onChanged: (type) {
                    if (type != null) {
                      setDialogState(() => selectedType = type);
                    }
                  },
                ),
                const SizedBox(height: 16),

                // Keywords
                const Text('Keywords (comma separated)'),
                const SizedBox(height: 8),
                TextField(
                  controller: keywordsController,
                  decoration: const InputDecoration(
                    hintText: 'keyword1, keyword2, ...',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final content = contentController.text.trim();
                if (content.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Content cannot be empty')),
                  );
                  return;
                }
                final keywords = keywordsController.text
                    .split(',')
                    .map((k) => k.trim())
                    .where((k) => k.isNotEmpty)
                    .toList();
                Navigator.pop(context, {
                  'content': content,
                  'type': selectedType,
                  'keywords': keywords,
                });
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      try {
        await _memoryService.addMemory(
          agentId: widget.agent.id,
          content: result['content'] as String,
          type: result['type'] as MemoryType,
          keywords: result['keywords'] as List<String>?,
          sourceType: MemorySourceType.system, // 手动添加标记为 system
        );
        await _loadMemories();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Memory added')),
          );
        }
      } catch (e) {
        LoggerService().error(
          'Failed to add memory',
          tag: 'AgentMemoryDetail',
          error: e,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to add memory')),
          );
        }
      }
    }

    contentController.dispose();
    keywordsController.dispose();
  }

  Future<void> _deleteMemory(int memoryId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Memory'),
        content: const Text('Delete this memory?'),
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
      await _memoryService.deleteMemory(widget.agent.id, memoryId);
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
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Export as ${format.toUpperCase()}'),
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
          : Column(
              children: [
                // 搜索栏
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: SearchBar(
                    hintText: 'Search memories...',
                    onChanged: (keyword) {
                      if (keyword.isEmpty) {
                        _loadMemories();
                      }
                    },
                    onSubmitted: (keyword) {
                      _loadMemories(keyword: keyword);
                    },
                  ),
                ),
                // 内容
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildStructuredView(),
                      _buildTimelineView(),
                    ],
                  ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addMemory,
        tooltip: 'Add Memory',
        child: const Icon(Icons.add),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Colors.grey[300]!)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
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
              'No Memories Found',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              _filterKeyword != null ? 'Try different keywords' : 'Add memories to get started',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[500],
                  ),
            ),
          ],
        ),
      );
    }

    // 按类型分组
    final grouped = <MemoryType, List<AgentMemoryEntry>>{};
    for (final memory in _memories) {
      grouped.putIfAbsent(memory.memoryType, () => []).add(memory);
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: grouped.length,
      itemBuilder: (context, groupIndex) {
        final type = grouped.keys.elementAt(groupIndex);
        final memories = grouped[type]!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text(
                type.displayName,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ...memories.map((memory) => _buildMemoryCard(memory)).toList(),
          ],
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            memory.memoryType.displayName,
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (memory.sourceType != null)
                            Text(
                              '${memory.sourceType}${memory.sourceId != null ? ' (${memory.sourceId})' : ''}',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.grey[600],
                              ),
                            ),
                        ],
                      ),
                    ),
                    Text(
                      memory.memoryTimeFormatted,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey[600],
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  memory.memoryContent,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                if (memory.memoryKeywords.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 4,
                    children: memory.memoryKeywords
                        .map((kw) => Chip(
                          label: Text(kw, style: const TextStyle(fontSize: 12)),
                          visualDensity: VisualDensity.compact,
                        ))
                        .toList(),
                  ),
                ],
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
                      onPressed: () => _deleteMemory(memory.memoryId!),
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

  Widget _buildMemoryCard(AgentMemoryEntry memory) {
    return Card(
      child: ListTile(
        title: Text(
          memory.memoryType.displayName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          memory.memoryContent,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete, color: Colors.red),
          onPressed: () => _deleteMemory(memory.memoryId!),
        ),
        onTap: () => _showMemoryDetail(memory),
      ),
    );
  }

  void _showMemoryDetail(AgentMemoryEntry memory) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(memory.memoryType.displayName),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'ID: ${memory.memoryId}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Recorded: ${memory.memoryTimeFormatted}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                ),
              ),
              if (memory.sourceType != null)
                Text(
                  'Source: ${memory.sourceType}${memory.sourceId != null ? ' (${memory.sourceId})' : ''}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
                ),
              if (memory.memoryKeywords.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Keywords:',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Wrap(
                  spacing: 4,
                  children: memory.memoryKeywords
                      .map((kw) => Chip(
                        label: Text(kw, style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                      ))
                      .toList(),
                ),
              ],
              const SizedBox(height: 12),
              SelectableText(memory.memoryContent),
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
