import '../../cli_base.dart';
import '../../../services/she_service.dart';
import '../../../services/cognition_service.dart';

/// 追加 Agent 的记忆（增量更新）
///
/// - She（she-builtin-agent-001）：使用 SheService（支持 long_term_memory / self_notes）
/// - 其他 Agent：使用 CognitionService（仅支持 self_notes，追加到现有内容）
class AppendCommand extends CliCommand {
  final String agentId;

  AppendCommand({required this.agentId});

  bool get _isShe => agentId == SheService.sheId;

  @override
  String get name => 'append';

  @override
  String get description => 'Append content, --key long_term_memory|self_notes --value <val>';

  @override
  String get usage => 'shepaw context memory.append --key long_term_memory|self_notes --value "..."';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'key': {
        'description': 'Memory key to append to',
        'required': true,
        'type': 'string',
        'enum': _isShe ? ['long_term_memory', 'self_notes'] : ['self_notes'],
      },
      'value': {
        'description': 'Text to append (added as a new entry, not replacing existing content)',
        'required': true,
        'type': 'string',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final key = flags['key'];
    final value = flags['value'];
    if (key == null || key.isEmpty) {
      return {'error': 'Missing --key. Usage: shepaw memory append --key long_term_memory --value "..."'};
    }
    if (value == null) {
      return {'error': 'Missing --value parameter'};
    }

    if (_isShe) {
      // She 使用专用路径
      if (key == 'long_term_memory') {
        await SheService.instance.appendMemory(value);
      } else if (key == 'self_notes') {
        await SheService.instance.appendSelfNote(value);
      } else {
        return {
          'error': 'Invalid key "$key". Supported keys for She: long_term_memory, self_notes',
        };
      }
    } else {
      // 其他 Agent：读取现有 self_notes，追加新内容后写回
      if (key != 'self_notes') {
        return {
          'error': 'Only "self_notes" is supported for append on this agent. Use "write" for "soul".',
        };
      }
      final existing = await CognitionService.instance.getAgentSelfNotes(agentId) ?? '';
      final timestamp = DateTime.now().toIso8601String();
      final appended = existing.isEmpty
          ? '[$timestamp] $value'
          : '$existing\n[$timestamp] $value';
      await CognitionService.instance.updateAgentSelfNotes(agentId, appended);
    }

    return {'ok': true, 'key': key, 'appended': value};
  }
}
