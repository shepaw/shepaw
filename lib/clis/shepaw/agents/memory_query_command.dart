import '../../cli_base.dart';
import '../../../models/agent_memory_entry.dart';
import '../../../services/agent_memory_biz_service.dart';

/// 查询 Agent 记忆
///
/// 用法：
///   shepaw agents memory query --id <agent_id> [--limit 20]
///   shepaw agents memory query --id <agent_id> --keywords user,preference [--limit 20]
class MemoryQueryCommand extends CliCommand {
  @override
  String get name => 'memory-query';

  @override
  String get description =>
      'Query agent memories, --id <agent_id> [--keywords k1,k2] [--type conversation] [--limit 20]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id'];
    if (id == null || id.isEmpty) {
      return {
        'error':
            'Missing --id. Usage: shepaw agents memory query --id <agent_id> [--keywords k1,k2] [--limit 20]',
      };
    }

    final limit = int.tryParse(flags['limit'] ?? '20') ?? 20;
    final keywordsArg = flags['keywords'];
    final typeArg = flags['type'];

    final svc = AgentMemoryBizService();

    List<AgentMemoryEntry> memories;

    if (keywordsArg != null && keywordsArg.isNotEmpty) {
      // 关键词搜索：多个关键词 OR 匹配
      final keywords = keywordsArg.split(',').map((k) => k.trim()).toList();
      final results = <AgentMemoryEntry>[];
      final seen = <int>{};
      for (final kw in keywords) {
        final hits = await svc.queryByKeyword(id, kw, limit: limit);
        for (final h in hits) {
          if (h.memoryId != null && seen.add(h.memoryId!)) {
            results.add(h);
          }
        }
      }
      results.sort((a, b) => b.memoryTime.compareTo(a.memoryTime));
      memories = results.take(limit).toList();
    } else {
      // 类型过滤 or 全量
      MemoryType? type;
      if (typeArg != null && typeArg.isNotEmpty) {
        type = MemoryType.values.where((t) => t.name == typeArg).firstOrNull;
      }
      memories = await svc.getAllMemories(id, type: type, limit: limit);
    }

    final list = memories.map((m) {
      return {
        'id': m.memoryId,
        'content': m.memoryContent,
        'type': m.memoryType.name,
        'keywords': m.memoryKeywords,
        'source_type': m.sourceType,
        'memory_time': m.memoryTimeFormatted,
      };
    }).toList();

    return {
      'agent_id': id,
      'count': list.length,
      'memories': list,
    };
  }
}
