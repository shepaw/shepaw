import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final svc = PeerAgentClientService.instance;

  setUp(() => svc.debugResetPeerMetaForTest());
  tearDown(() => svc.debugResetPeerMetaForTest());

  test('engineStatus 解析引擎占用与汇总', () async {
    final sent = <Map<String, dynamic>>[];
    svc.debugSendControlOverride = (peerId, json) async {
      sent.add(json);
      scheduleMicrotask(() {
        svc.debugInjectControlForTest(
          'engine_status_resp',
          {
            'request_id': json['request_id'],
            'ok': true,
            'scanned_at': 1730000000000,
            'engines': [
              {
                'id': 'claude-code',
                'name': 'Claude Code',
                'command': 'claude',
                'available': true,
                'instance_count': 2,
                'connections': 1,
                'active_conversations': 1,
                'queued': 3,
                'queued_sessions': 1,
                'instances': [
                  {
                    'id': 'i1',
                    'name': '项目',
                    'connections': 1,
                    'active_conversations': 1,
                    'queued': 3,
                    'queued_sessions': 1,
                    'sessions': [
                      {
                        'session_key': 'session-a',
                        'running': true,
                        'queued': 3,
                      },
                    ],
                  },
                ],
              },
              {
                'id': 'codex',
                'name': 'Codex',
                'command': 'codex',
                'available': false,
                'unavailable_reason': '主机上找不到命令 codex',
                'instance_count': 0,
                'connections': 0,
                'active_conversations': 0,
              },
            ],
            'summary': {
              'engines': 2,
              'available_engines': 1,
              'instances': 2,
              'enabled_instances': 2,
              'connections': 1,
              'active_conversations': 1,
              'queued': 3,
              'queued_sessions': 1,
            },
          },
          peerId: peerId,
        );
      });
      return true;
    };

    final result = await svc.engineStatus(
      peerId: 'host-1',
      nodeId: 'node-1',
      refresh: true,
    );

    expect(sent, hasLength(1));
    expect(sent.single['type'], 'engine_status_req');
    expect(sent.single['node_id'], 'node-1');
    expect(sent.single['refresh'], isTrue);
    expect(result.ok, isTrue);
    expect(result.scannedAt, 1730000000000);
    expect(result.engines, hasLength(2));
    expect(result.engines.first.connections, 1);
    expect(result.engines.first.queued, 3);
    expect(result.engines.first.queuedSessions, 1);
    expect(result.engines.first.instances.single.sessions.single.running, isTrue);
    expect(result.engines.last.available, isFalse);
    expect(result.engines.last.unavailableReason, contains('codex'));
    expect(result.summary.engines, 2);
    expect(result.summary.availableEngines, 1);
    expect(result.summary.connections, 1);
    expect(result.summary.activeConversations, 1);
    expect(result.summary.queued, 3);
    expect(result.summary.queuedSessions, 1);
  });

  test('旧主机没有 summary 时按引擎字段求和', () async {
    svc.debugSendControlOverride = (peerId, json) async {
      scheduleMicrotask(() {
        svc.debugInjectControlForTest(
          'engine_status_resp',
          {
            'request_id': json['request_id'],
            'ok': true,
            'engines': [
              {
                'id': 'claude-code',
                'name': 'Claude Code',
                'available': true,
                'instance_count': 2,
                'connections': 2,
                'active_conversations': 1,
              },
              {
                'id': 'codex',
                'name': 'Codex',
                'available': true,
                'instance_count': 1,
                'connections': 1,
                'active_conversations': 0,
              },
            ],
          },
          peerId: peerId,
        );
      });
      return true;
    };

    final result = await svc.engineStatus(peerId: 'host-1');

    expect(result.ok, isTrue);
    expect(result.summary.engines, 2);
    expect(result.summary.availableEngines, 2);
    expect(result.summary.instances, 3);
    expect(result.summary.connections, 3);
    expect(result.summary.activeConversations, 1);
    expect(result.summary.queued, 0);
  });

  test('主机不回包时按超时/不支持收尾', () async {
    svc.debugSendControlOverride = (peerId, json) async => true;

    final result = await svc.engineStatus(
      peerId: 'host-1',
      timeout: const Duration(milliseconds: 20),
    );

    expect(result.ok, isFalse);
    expect(result.unsupported, isTrue);
    expect(result.error, 'timeout');
  });

  test('发不出去时直接报离线', () async {
    svc.debugSendControlOverride = (peerId, json) async => false;

    final result = await svc.engineStatus(peerId: 'host-1');

    expect(result.ok, isFalse);
    expect(result.error, 'offline');
    expect(result.unsupported, isFalse);
  });

  test('engineControl 发杀进程/结束会话并解析计数', () async {
    final sent = <Map<String, dynamic>>[];
    svc.debugSendControlOverride = (peerId, json) async {
      sent.add(json);
      scheduleMicrotask(() {
        svc.debugInjectControlForTest(
          'engine_control_resp',
          {
            'request_id': json['request_id'],
            'ok': true,
            'killed': json['op'] == 'kill_instance' ? 2 : 1,
            'dropped': json['op'] == 'kill_session' ? 3 : 0,
          },
          peerId: peerId,
        );
      });
      return true;
    };

    final killed = await svc.engineControl(
      peerId: 'host-1',
      nodeId: 'node-1',
      op: 'kill_instance',
      instanceId: 'i1@node-1',
    );
    expect(sent.first['type'], 'engine_control_req');
    expect(sent.first['op'], 'kill_instance');
    expect(sent.first['instance_id'], 'i1@node-1');
    expect(sent.first['node_id'], 'node-1');
    expect(killed.ok, isTrue);
    expect(killed.killed, 2);

    final session = await svc.engineControl(
      peerId: 'host-1',
      op: 'kill_session',
      instanceId: 'i1',
      sessionKey: 'session-a',
    );
    expect(sent.last['session_key'], 'session-a');
    expect(session.killed, 1);
    expect(session.dropped, 3);
  });

  test('engineControl 主机不回包时按不支持处理', () async {
    svc.debugSendControlOverride = (peerId, json) async => true;

    final result = await svc.engineControl(
      peerId: 'host-1',
      op: 'kill_instance',
      instanceId: 'i1',
      timeout: const Duration(milliseconds: 20),
    );

    expect(result.ok, isFalse);
    expect(result.unsupported, isTrue);
  });
}
