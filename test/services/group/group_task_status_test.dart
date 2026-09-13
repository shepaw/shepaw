import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/group/group_member_stall.dart';
import 'package:shepaw/services/group/group_task_status.dart';
import 'package:shepaw/services/group/group_turn_result.dart';
import 'package:shepaw/services/task/task_models.dart';
import 'package:shepaw/services/group/group_background_interrupt.dart';

RemoteAgent _agent(String id, String name) => RemoteAgent(
      id: id,
      name: name,
      avatar: '🤖',
      token: '',
      endpoint: '',
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.http,
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  group('GroupTaskStatusParser.parse', () {
    test('done on last line', () {
      final info = GroupTaskStatusParser.parse('写完了报告\n[TASK_STATUS: done]');
      expect(info.applicable, isTrue);
      expect(info.status, GroupMemberTaskStatus.done);
      expect(info.reason, isNull);
    });

    test('pending with 原因', () {
      final info = GroupTaskStatusParser.parse(
        '还差 API key\n[TASK_STATUS: pending] 原因：缺少密钥',
      );
      expect(info.status, GroupMemberTaskStatus.pending);
      expect(info.reason, '缺少密钥');
    });

    test('pending with English reason:', () {
      final info = GroupTaskStatusParser.parse(
        '[TASK_STATUS: pending] reason: waiting for user',
      );
      expect(info.status, GroupMemberTaskStatus.pending);
      expect(info.reason, 'waiting for user');
    });

    test('last tag wins when multiple present', () {
      final info = GroupTaskStatusParser.parse(
        '[TASK_STATUS: done]\n中间说明\n[TASK_STATUS: pending] 原因：还要改',
      );
      expect(info.status, GroupMemberTaskStatus.pending);
      expect(info.reason, '还要改');
    });

    test('missing annotation on a real reply', () {
      final info = GroupTaskStatusParser.parse('这是一段没有状态标注的回复');
      expect(info.applicable, isTrue);
      expect(info.status, GroupMemberTaskStatus.missing);
    });

    test('empty and SKIP are not applicable', () {
      expect(GroupTaskStatusParser.parse('').applicable, isFalse);
      expect(GroupTaskStatusParser.parse('  \n  ').applicable, isFalse);
      expect(
        GroupTaskStatusParser.parse('无事可做 [SKIP]').applicable,
        isFalse,
      );
    });
  });

  group('GroupTaskStatusParser.blockingMembers', () {
    final coder = _agent('coder', 'Coder');
    final writer = _agent('writer', 'Writer');

    test('pending and missing block; done and skip do not', () {
      final pending = GroupTaskStatusParser.blockingMembers(
        turns: {
          'coder': GroupTurnResult(
            content: '还没做完\n[TASK_STATUS: pending] 原因：缺图',
            taskStatusInfo: GroupTaskStatusParser.parse(
              '还没做完\n[TASK_STATUS: pending] 原因：缺图',
            ),
          ),
          'writer': GroupTurnResult(
            content: '全文如下……\n[TASK_STATUS: done]',
            taskStatusInfo: GroupTaskStatusParser.parse(
              '全文如下……\n[TASK_STATUS: done]',
            ),
          ),
          'skipper': const GroupTurnResult(content: '[SKIP]'),
        },
        agents: [coder, writer],
      );
      expect(pending, hasLength(1));
      expect(pending.single.name, 'Coder');
      expect(pending.single.status, GroupMemberTaskStatus.pending);
      expect(pending.single.reason, '缺图');
    });

    test('missing annotation on a real reply is blocking', () {
      final pending = GroupTaskStatusParser.blockingMembers(
        turns: {
          'coder': const GroupTurnResult(content: '我写好了但忘了标注'),
        },
        agents: [coder],
      );
      expect(pending, hasLength(1));
      expect(pending.single.status, GroupMemberTaskStatus.missing);
      expect(pending.single.display, contains('未标注'));
    });

    test('empty failed-turn results are not blocking', () {
      final pending = GroupTaskStatusParser.blockingMembers(
        turns: {
          'coder': const GroupTurnResult(),
        },
        agents: [coder],
      );
      expect(pending, isEmpty);
    });

    test('nudge and exhausted copy name the members', () {
      const members = [
        GroupPendingMember(
          agentId: 'coder',
          name: 'Coder',
          status: GroupMemberTaskStatus.pending,
          reason: '缺图',
        ),
      ];
      expect(GroupTaskStatusParser.nudgeSystemContent(members), contains('Coder（缺图）'));
      expect(GroupTaskStatusParser.nudgeSystemContent(members), contains('禁止'));
      expect(GroupTaskStatusParser.exhaustedWarning(members), contains('Coder（缺图）'));
      expect(GroupTaskStatusParser.adminNote(members), contains('group_finish'));
      expect(
        GroupTaskStatusParser.mentionPathWarning(members),
        contains('可再次 @ 他们补做'),
      );
    });
  });

  group('GroupTaskStatusParser.strip', () {
    test('removes last-line tag and reason', () {
      expect(
        GroupTaskStatusParser.strip('写完了报告\n[TASK_STATUS: done]'),
        '写完了报告',
      );
      expect(
        GroupTaskStatusParser.strip('还差图\n[TASK_STATUS: pending] 原因：缺图'),
        '还差图',
      );
    });

    test('strips every tag when several are present', () {
      expect(
        GroupTaskStatusParser.strip(
          '[TASK_STATUS: done]\n中间说明\n[TASK_STATUS: pending] 原因：还要改',
        ),
        '中间说明',
      );
    });

    test('is a no-op when there is no tag', () {
      expect(GroupTaskStatusParser.strip('普通回复'), '普通回复');
      expect(GroupTaskStatusParser.strip(''), '');
    });
  });

  group('GroupTaskStatusParser.displayInfo', () {
    test('prefers metadata over leftover content tag', () {
      final info = GroupTaskStatusParser.displayInfo(
        content: '正文\n[TASK_STATUS: pending] 原因：旧',
        metadata: {
          GroupTaskStatusParser.metadataStatusKey: 'done',
        },
      );
      expect(info?.status, GroupMemberTaskStatus.done);
      expect(info?.reason, isNull);
    });

    test('falls back to content tag when metadata is absent', () {
      final info = GroupTaskStatusParser.displayInfo(
        content: '还差图\n[TASK_STATUS: pending] 原因：缺图',
      );
      expect(info?.status, GroupMemberTaskStatus.pending);
      expect(info?.reason, '缺图');
    });

    test('does not badge a historical reply with neither metadata nor tag', () {
      expect(
        GroupTaskStatusParser.displayInfo(content: '很久以前的成员回复'),
        isNull,
      );
    });

    test('metadata missing is shown as unmarked', () {
      final info = GroupTaskStatusParser.displayInfo(
        content: '忘了标注',
        metadata: {
          GroupTaskStatusParser.metadataStatusKey: 'missing',
        },
      );
      expect(info?.status, GroupMemberTaskStatus.missing);
    });
  });

  group('GroupTaskStatusParser NEED_ADMIN wake (PR-8)', () {
    final coder = _agent('coder', 'Coder');

    test('requestsAdminWake when pending reason contains tag', () {
      final info = GroupTaskStatusParser.parse(
        '[TASK_STATUS: pending] 原因：[NEED_ADMIN] 选 A 还是 B？',
      );
      expect(GroupTaskStatusParser.requestsAdminWake(info), isTrue);
    });

    test('membersNeedingAdminWake collects tagged pending members', () {
      final wake = GroupTaskStatusParser.membersNeedingAdminWake(
        turns: {
          'coder': GroupTurnResult(
            content:
                'blocked\n[TASK_STATUS: pending] 原因：[NEED_ADMIN] 需要选数据库',
            taskStatusInfo: GroupTaskStatusParser.parse(
              'blocked\n[TASK_STATUS: pending] 原因：[NEED_ADMIN] 需要选数据库',
            ),
          ),
        },
        agents: [coder],
      );
      expect(wake, hasLength(1));
      expect(wake.single.name, 'Coder');
      expect(wake.single.reason, contains('[NEED_ADMIN]'));
    });

    test('adminPendingWakeNote lists members for mid-loop turn', () {
      final note = GroupTaskStatusParser.adminPendingWakeNote(const [
        MemberAdminWakeRequest(
          agentId: 'coder',
          name: 'Coder',
          reason: '[NEED_ADMIN] Redis 还是 Postgres',
        ),
      ]);
      expect(note, contains('[NEED_ADMIN]'));
      expect(note, contains('Coder'));
      expect(note, contains('mid-loop'));
      expect(note, contains('group_dispatch'));
    });

    test('adminStalledFollowUpNote lists timeout members', () {
      final note = GroupTaskStatusParser.adminStalledFollowUpNote(const [
        MemberStallRequest(
          agentId: 'coder',
          name: 'Coder',
          timeout: Duration(minutes: 10),
          stallCount: 1,
        ),
      ]);
      expect(note, contains('stalled'));
      expect(note, contains('Coder'));
      expect(note, contains('10 分钟'));
    });
  });

  group('GroupBackgroundInterrupt', () {
    test('only channels with a dead ACP in-flight task are selected', () {
      final tasks = <String, Map<String, GroupActiveTask>>{
        'g1': {
          'local': GroupActiveTask(
            agentId: 'local',
            agentName: 'Local',
            channelId: 'g1',
          ),
          'acp-dead': GroupActiveTask(
            agentId: 'acp-dead',
            agentName: 'Remote',
            channelId: 'g1',
          ),
        },
        'g2': {
          'acp-ok': GroupActiveTask(
            agentId: 'acp-ok',
            agentName: 'Ok',
            channelId: 'g2',
          ),
        },
        'g3': {
          'done': GroupActiveTask(
            agentId: 'acp-dead',
            agentName: 'DoneRemote',
            channelId: 'g3',
          )..isComplete = true,
        },
      };
      final ids = GroupBackgroundInterrupt.deadAcpChannelIds(
        activeGroupTasks: tasks,
        hasAcpConnection: (id) => id.startsWith('acp-'),
        isConnected: (id) => id == 'acp-ok',
      );
      expect(ids, ['g1']);
    });

    test('live in-memory loop is not a crash', () {
      expect(
        GroupBackgroundInterrupt.shouldNotifyCrashedOrchestration(
          latestStatus: 'running',
          liveInMemory: true,
        ),
        isFalse,
      );
    });

    test('non-terminal latest after process death is a crash', () {
      expect(
        GroupBackgroundInterrupt.shouldNotifyCrashedOrchestration(
          latestStatus: 'running',
          liveInMemory: false,
        ),
        isTrue,
      );
      expect(
        GroupBackgroundInterrupt.shouldNotifyCrashedOrchestration(
          latestStatus: 'dispatched',
          liveInMemory: false,
        ),
        isTrue,
      );
    });

    test('finished or missing latest is not a crash', () {
      expect(
        GroupBackgroundInterrupt.shouldNotifyCrashedOrchestration(
          latestStatus: 'finished',
          liveInMemory: false,
        ),
        isFalse,
      );
      expect(
        GroupBackgroundInterrupt.shouldNotifyCrashedOrchestration(
          latestStatus: null,
          liveInMemory: false,
        ),
        isFalse,
      );
    });

    test('local-only in-flight channels are left running', () {
      final tasks = <String, Map<String, GroupActiveTask>>{
        'g-local': {
          'local': GroupActiveTask(
            agentId: 'local',
            agentName: 'Local',
            channelId: 'g-local',
          ),
        },
      };
      final ids = GroupBackgroundInterrupt.deadAcpChannelIds(
        activeGroupTasks: tasks,
        hasAcpConnection: (_) => false,
        isConnected: (_) => false,
      );
      expect(ids, isEmpty);
    });
  });

  group('GroupTaskStatusParser.shouldHaltRemainingSequentialSteps', () {
    final coder = _agent('coder', 'Coder');

    test('halts when the step is pending / NEED_ADMIN', () {
      final turn = GroupTurnResult(
        content: 'store.write approval_denied\n'
            '[TASK_STATUS: pending] 原因：[NEED_ADMIN] 通道被拒',
        taskStatusInfo: GroupTaskStatusParser.parse(
          'store.write approval_denied\n'
          '[TASK_STATUS: pending] 原因：[NEED_ADMIN] 通道被拒',
        ),
      );
      expect(
        GroupTaskStatusParser.shouldHaltRemainingSequentialSteps(
          stepTurns: {'coder': turn},
          agents: [coder],
        ),
        isTrue,
      );
      expect(GroupTaskStatusParser.looksChannelBlocked(turn), isTrue);
    });

    test('does not halt a completed step', () {
      final turn = GroupTurnResult(
        content: '四份文件已落盘\n[TASK_STATUS: done]',
        taskStatusInfo: GroupTaskStatusParser.parse(
          '四份文件已落盘\n[TASK_STATUS: done]',
        ),
      );
      expect(
        GroupTaskStatusParser.shouldHaltRemainingSequentialSteps(
          stepTurns: {'coder': turn},
          agents: [coder],
        ),
        isFalse,
      );
    });

    test('halts an empty step so later reviewers are not launched', () {
      expect(
        GroupTaskStatusParser.shouldHaltRemainingSequentialSteps(
          stepTurns: const {},
          agents: [coder],
        ),
        isTrue,
      );
    });
  });
}
