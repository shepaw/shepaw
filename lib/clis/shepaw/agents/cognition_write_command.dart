import '../../cli_base.dart';
import '../../../services/cognition_service.dart';

/// 写入/更新 Agent 的认知数据
///
/// 用法 - 更新 soul（self cognition）:
///   shepaw agents cognition-write --id <agent_id> --type self --soul "I am a helpful assistant..."
///
/// 用法 - 更新对用户的印象或笔记（user cognition）:
///   shepaw agents cognition-write --id <agent_id> --type user --field impression --value "User prefers concise replies"
///   shepaw agents cognition-write --id <agent_id> --type user --field notes --value "User has a cat named Mochi"
class CognitionWriteCommand extends CliCommand {
  @override
  String get name => 'cognition-write';

  @override
  String get description =>
      'Write agent cognition, --id <agent_id> --type self|user [--soul "..." | --field impression|notes --value "..."]';

  @override
  String get usage =>
      'shepaw context agents.cognition-write --id <agent_id> --type self|user [--soul "..." | --field impression|notes --value "..."]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'id': {
        'description': 'Agent ID to update cognition for',
        'required': true,
        'type': 'string',
      },
      'type': {
        'description': 'Cognition type to write',
        'required': true,
        'type': 'string',
        'enum': ['self', 'user'],
      },
      'soul': {
        'description': 'Soul text to set (required when --type self)',
        'required': 'when type=self',
        'type': 'string',
      },
      'field': {
        'description': 'User cognition field to update (required when --type user)',
        'required': 'when type=user',
        'type': 'string',
        'enum': ['impression', 'notes'],
      },
      'value': {
        'description': 'Value to set for the chosen field (required when --type user)',
        'required': 'when type=user',
        'type': 'string',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id'];
    if (id == null || id.isEmpty) {
      return {
        'error':
            'Missing --id. Usage: shepaw agents cognition-write --id <agent_id> --type self|user ...',
      };
    }

    final typeArg = flags['type'];
    if (typeArg == null || typeArg.isEmpty) {
      return {
        'error':
            'Missing --type. Usage: --type self (with --soul) or --type user (with --field and --value)',
      };
    }

    final svc = CognitionService.instance;

    // 写入 self cognition (soul)
    if (typeArg == 'self') {
      final soul = flags['soul'];
      if (soul == null || soul.trim().isEmpty) {
        return {
          'error':
              'Missing --soul. Usage: shepaw agents cognition-write --id <agent_id> --type self --soul "..."',
        };
      }
      await svc.updateAgentSoul(id, soul.trim());
      return {
        'ok': true,
        'agent_id': id,
        'type': 'self',
        'field': 'soul',
        'value': soul.trim(),
      };
    }

    // 写入 user cognition (impression / notes)
    if (typeArg == 'user') {
      final field = flags['field'];
      final value = flags['value'];

      if (field == null ||
          field.isEmpty ||
          (field != 'impression' && field != 'notes')) {
        return {
          'error':
              'Invalid --field. Use --field impression or --field notes',
        };
      }
      if (value == null || value.trim().isEmpty) {
        return {
          'error': 'Missing --value',
        };
      }

      if (field == 'impression') {
        await svc.updateUserImpression(id, value.trim());
      } else if (field == 'notes') {
        await svc.updateUserNotes(id, value.trim());
      }

      return {
        'ok': true,
        'agent_id': id,
        'type': 'user',
        'field': field,
        'value': value.trim(),
      };
    }

    return {
      'error': 'Invalid --type. Use --type self or --type user',
    };
  }
}
