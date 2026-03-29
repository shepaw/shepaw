import '../../cli_base.dart';
import '../../../services/cognition_service.dart';

/// 查询 Agent 的认知数据（self cognition + user cognition）
///
/// 用法：
///   shepaw agents cognition-query --id <agent_id>                    (查询全部)
///   shepaw agents cognition-query --id <agent_id> --type self        (仅查询 soul/self_notes)
///   shepaw agents cognition-query --id <agent_id> --type user        (仅查询对用户的理解)
class CognitionQueryCommand extends CliCommand {
  @override
  String get name => 'cognition-query';

  @override
  String get description =>
      'Query agent cognition (self + user), --id <agent_id> [--type self|user]';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'flags': {
          'id': {
            'description': 'Agent ID to query cognition for',
            'required': true,
            'type': 'string',
          },
          'type': {
            'description': 'Filter by cognition type (omit to query both)',
            'required': false,
            'type': 'string',
            'enum': ['self', 'user'],
            'self_returns': ['soul', 'self_notes', 'capabilities', 'updated_at'],
            'user_returns': ['user_profile', 'user_impression', 'user_notes', 'last_updated'],
          },
        },
        'usage':
            'shepaw context agents.cognition-query --id <agent_id> [--type self|user]',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id'];
    if (id == null || id.isEmpty) {
      return {
        'error':
            'Missing --id. Usage: shepaw agents cognition-query --id <agent_id> [--type self|user]',
      };
    }

    final typeArg = flags['type'];
    final svc = CognitionService.instance;

    final result = <String, dynamic>{'agent_id': id};

    // 查询 self cognition
    if (typeArg == null || typeArg.isEmpty || typeArg == 'self') {
      final self = await svc.getSelfCognition(id);
      if (self != null) {
        result['self_cognition'] = {
          'soul': self.soul.isNotEmpty ? self.soul : '(empty)',
          'self_notes': self.selfNotes?.isNotEmpty == true
              ? self.selfNotes
              : '(no notes)',
          'capabilities': self.capabilities,
          'updated_at': self.updatedAt,
        };
      } else {
        result['self_cognition'] = null;
      }
    }

    // 查询 user cognition
    if (typeArg == null || typeArg.isEmpty || typeArg == 'user') {
      final user = await svc.getUserCognition(id);
      if (user != null) {
        result['user_cognition'] = {
          'user_profile': user.userProfile.isEmpty ? {}  : user.userProfile,
          'user_impression': user.userImpression?.isNotEmpty == true
              ? user.userImpression
              : '(no impression yet)',
          'user_notes': user.userNotes?.isNotEmpty == true
              ? user.userNotes
              : '(no notes)',
          'last_updated': user.lastUpdated,
        };
      } else {
        result['user_cognition'] = null;
      }
    }

    return result;
  }
}
