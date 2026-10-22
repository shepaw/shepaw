import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

void main() {
  test('引擎回包带上头像、文档和启动命令', () {
    final engine = PeerEngineEntry.fromJson({
      'id': 'claude-code',
      'name': 'Claude Code',
      'command': 'npx',
      'available': false,
      'unavailable_reason': '主机上找不到命令 npx',
      'avatar_data': 'PHN2Zy8+',
      'avatar_ext': 'svg',
      'docs_url': 'https://agentclientprotocol.com',
      'acp_command': 'npx -y @agentclientprotocol/claude-agent-acp@latest',
      'instance_count': 3,
      'connections': 2,
      'active_conversations': 1,
      'queued': 4,
      'queued_sessions': 2,
      'instances': [
        {
          'id': 'i1',
          'name': '项目',
          'cwd': '/work',
          'connections': 1,
          'active_conversations': 1,
          'queued': 4,
          'queued_sessions': 2,
          'sessions': [
            {
              'session_key': 'session-a',
              'running': true,
              'idle': false,
              'queued': 4,
            },
          ],
        },
      ],
    });
    expect(engine.available, isFalse);
    expect(engine.avatarData, 'PHN2Zy8+');
    expect(engine.avatarExt, 'svg');
    expect(engine.docsUrl, 'https://agentclientprotocol.com');
    expect(engine.acpCommand, contains('claude-agent-acp'));
    expect(engine.unavailableReason, contains('npx'));
    expect(engine.instanceCount, 3);
    expect(engine.connections, 2);
    expect(engine.activeConversations, 1);
    expect(engine.queued, 4);
    expect(engine.queuedSessions, 2);
    final instance = engine.instances.single;
    expect(instance.id, 'i1');
    expect(instance.queued, 4);
    expect(instance.sessions.single.sessionKey, 'session-a');
    expect(instance.sessions.single.running, isTrue);
    expect(instance.sessions.single.queued, 4);
  });

  test('旧回包没有占用字段时默认为零', () {
    final engine = PeerEngineEntry.fromJson({
      'id': 'codex',
      'name': 'Codex',
      'available': true,
    });
    expect(engine.instanceCount, 0);
    expect(engine.connections, 0);
    expect(engine.activeConversations, 0);
    expect(engine.queued, 0);
    expect(engine.queuedSessions, 0);
    expect(engine.instances, isEmpty);
  });
}
