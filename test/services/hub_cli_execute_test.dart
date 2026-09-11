import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/cli_execution_gate.dart';
import 'package:shepaw/services/hub_cli_execute.dart';

/// 群会话夹具：`admin-1` 是管理员，`member-1` 是普通成员。
Channel _groupChannel() => Channel(
      id: 'group-1',
      name: 'Group',
      type: 'group',
      members: [
        ChannelMember(id: 'admin-1', type: 'agent', role: 'admin', joinedAt: 0),
        ChannelMember(id: 'member-1', type: 'agent', role: 'member', joinedAt: 0),
      ],
    );

void main() {
  group('HubCliExecute.sanitizeFlags', () {
    test('drops forged identity fields and keeps the rest', () {
      final flags = HubCliExecute.sanitizeFlags({
        'uri': 'store://runtime/d/a/x',
        'agent_id': 'forged-agent',
        'owner': 'forged-owner',
        'channel_id': 'forged-channel',
        'channel': 'also-forged',
        'filename': 'notes.md',
      });
      expect(flags['uri'], 'store://runtime/d/a/x');
      expect(flags['filename'], 'notes.md');
      expect(flags.containsKey('agent_id'), isFalse);
      expect(flags.containsKey('owner'), isFalse);
      expect(flags.containsKey('channel_id'), isFalse);
      expect(flags.containsKey('channel'), isFalse);
    });

    test('empty or non-map flags become {}', () {
      expect(HubCliExecute.sanitizeFlags(null), isEmpty);
      expect(HubCliExecute.sanitizeFlags('x'), isEmpty);
    });
  });

  group('HubCliExecute.boundSessionId', () {
    test('reads session_id only', () {
      expect(
        HubCliExecute.boundSessionId({
          'session_id': 'sess-1',
          'channel_id': 'ignored',
        }),
        'sess-1',
      );
      expect(HubCliExecute.boundSessionId({'channel_id': 'nope'}), isNull);
      expect(HubCliExecute.boundSessionId({'session_id': '  '}), isNull);
    });
  });

  group('HubCliExecute.resolveSessionId', () {
    test('prefers explicit session_id over the in-flight fallback', () {
      expect(
        HubCliExecute.resolveSessionId(
          {'session_id': 'from-agent'},
          activeFallback: 'group-9',
        ),
        'from-agent',
      );
    });

    test('omitted session_id uses the in-flight group/DM turn', () {
      expect(
        HubCliExecute.resolveSessionId({}, activeFallback: 'group-9'),
        'group-9',
      );
      expect(HubCliExecute.resolveSessionId({}), isNull);
    });
  });

  group('HubCliExecute.scopeOf', () {
    test('group-bound member session maps to the group bag', () {
      final ch = Channel.withMemberIds(
        id: 'dm-member',
        name: 'Member',
        type: 'dm',
        memberIds: ['user-1', 'agent-1'],
        sourceGroupChannelId: 'group-9',
      );
      expect(HubCliExecute.isMember(ch, 'agent-1'), isTrue);
      expect(HubCliExecute.isMember(ch, 'stranger'), isFalse);
      final scope = HubCliExecute.scopeOf(ch, 'agent-1');
      expect(scope.channelId, 'group-9');
      expect(scope.runtimeOwnerId, 'group-9');
    });

    test('plain DM keeps the session channel', () {
      final ch = Channel.withMemberIds(
        id: 'dm-1',
        name: 'DM',
        type: 'dm',
        memberIds: ['user-1', 'agent-1'],
      );
      final scope = HubCliExecute.scopeOf(ch, 'agent-1');
      expect(scope.channelId, 'dm-1');
      expect(scope.runtimeOwnerId, 'agent-1');
    });
  });

  /// P0-3 回归：远端 ACP 群成员此前没有角色收敛。
  ///
  /// 同一个群、同一个非管理员角色，本地 agent 被限到 `{store, help}`，远端
  /// agent 却拿到 `enabledCliCommands` 允许的全部命令——而它默认是「不受限」，
  /// 所以默认配置下远端成员能在群里跑 `os.command.exec`。
  group('HubCliExecute.extraAllowlistFor', () {
    test('群里的非管理员成员被收窄到 store/help', () {
      expect(
        HubCliExecute.extraAllowlistFor(_groupChannel(), 'member-1'),
        kGroupMemberCliAllowlist,
      );
    });

    test('群管理员不受额外限制', () {
      expect(HubCliExecute.extraAllowlistFor(_groupChannel(), 'admin-1'), isNull);
    });

    test('DM 不受额外限制（角色收敛只针对群）', () {
      final dm = Channel.withMemberIds(
        id: 'dm-1',
        name: 'DM',
        type: 'dm',
        memberIds: ['user-1', 'member-1'],
      );
      expect(HubCliExecute.extraAllowlistFor(dm, 'member-1'), isNull);
    });

    test('无绑定会话（非群上下文）不受额外限制', () {
      expect(HubCliExecute.extraAllowlistFor(null, 'member-1'), isNull);
    });

    test('收敛后的 allowlist 确实拦住 os.command.exec', () async {
      final raw = await CliExecutionGate.instance.execute(
        args: {
          'namespace': 'os',
          'subcommand': 'command.exec',
          'flags': {'cmd': 'ls'},
        },
        agentId: 'member-1',
        extraAllowlist:
            HubCliExecute.extraAllowlistFor(_groupChannel(), 'member-1'),
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(result['error'], contains('not allowed'));
      expect(result['allowed_commands'], contains('store'));
    });

    test('管理员（allowlist 为 null）不会被角色闸门拦下', () async {
      final raw = await CliExecutionGate.instance.execute(
        args: {
          'namespace': 'store',
          'subcommand': 'read',
          'flags': {},
        },
        agentId: 'admin-1',
        extraAllowlist:
            HubCliExecute.extraAllowlistFor(_groupChannel(), 'admin-1'),
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(result['error']?.toString() ?? '', isNot(contains('not allowed')));
    });
  });
}
