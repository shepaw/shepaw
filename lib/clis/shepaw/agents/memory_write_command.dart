import '../../cli_base.dart';
import '../../../models/agent_memory_entry.dart';
import '../../../services/agent_memory_biz_service.dart';

/// 写入 Agent 记忆
///
/// 用法：
///   shepaw agents memory write --id <agent_id> --content "..." [--type conversation] [--keywords k1,k2]
class MemoryWriteCommand extends CliCommand {
  @override
  String get name => 'memory-write';

  @override
  String get description =>
      'Write agent memory, --id <agent_id> --content "..." [--type conversation|knowledge|behavior|event|emotion] [--keywords k1,k2]';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'flags': {
          'id': {
            'description': 'Agent ID to write memory for',
            'required': true,
            'type': 'string',
          },
          'content': {
            'description': 'Memory text to store',
            'required': true,
            'type': 'string',
          },
          'type': {
            'description': 'Memory type for categorization',
            'required': false,
            'type': 'string',
            'enum': ['conversation', 'knowledge', 'behavior', 'event', 'emotion'],
            'default': 'conversation',
          },
          'keywords': {
            'description': 'Comma-separated keywords for future retrieval',
            'required': false,
            'type': 'string',
            'example': 'user,preference,hobby',
          },
        },
        'usage':
            'shepaw context agents.memory-write --id <agent_id> --content "..." [--type conversation] [--keywords k1,k2]',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id'];
    if (id == null || id.isEmpty) {
      return {
        'error':
            'Missing --id. Usage: shepaw agents memory write --id <agent_id> --content "..." [--type conversation] [--keywords k1,k2]',
      };
    }

    final content = flags['content'];
    if (content == null || content.trim().isEmpty) {
      return {
        'error': 'Missing --content. Provide the memory text to store.',
      };
    }

    final typeArg = flags['type'] ?? 'conversation';
    final type = MemoryType.values
            .where((t) => t.name == typeArg)
            .firstOrNull ??
        MemoryType.conversation;

    final keywordsArg = flags['keywords'];
    final keywords = (keywordsArg != null && keywordsArg.isNotEmpty)
        ? keywordsArg.split(',').map((k) => k.trim()).where((k) => k.isNotEmpty).toList()
        : <String>[];

    final memoryId = await AgentMemoryBizService().addMemory(
      agentId: id,
      content: content.trim(),
      type: type,
      keywords: keywords,
      sourceType: 'system',
    );

    return {
      'ok': true,
      'agent_id': id,
      'memory_id': memoryId,
      'type': type.name,
      'keywords': keywords,
      'content': content.trim(),
    };
  }
}
