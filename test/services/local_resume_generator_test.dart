import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/local_resume_generator.dart';

RemoteAgent _agent({
  String name = '小助手',
  String? bio,
  List<String> capabilities = const ['聊天', '搜索'],
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return RemoteAgent(
    id: 'a1',
    name: name,
    bio: bio,
    token: '',
    endpoint: '',
    protocol: ProtocolType.acp,
    connectionType: ConnectionType.websocket,
    status: AgentStatus.online,
    capabilities: capabilities,
    metadata: const {'llm_provider': 'openai'},
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('LocalResumeGenerator.buildRegenSystemPrompt', () {
    test('包含 agent 名并要求纯文本输出', () {
      final p = LocalResumeGenerator.buildRegenSystemPrompt(_agent());
      expect(p, contains('小助手'));
      expect(p, contains('resume'));
      // 只输出正文：禁止 markdown 标题 / 前言。
      expect(p.toLowerCase(), contains('no markdown'));
    });

    test('空名回退为 Agent', () {
      final p = LocalResumeGenerator.buildRegenSystemPrompt(
        _agent(name: '  '),
      );
      expect(p, contains('"Agent"'));
    });
  });

  group('LocalResumeGenerator.buildRegenUserMessage', () {
    test('包含当前简历、能力标签与改写要求', () {
      final msg = LocalResumeGenerator.buildRegenUserMessage(
        userPrompt: '更突出项目经验',
        currentResume: '旧的简历',
        capabilities: const ['聊天', ' 搜索 ', ''],
      );
      expect(msg, contains('当前简历:\n旧的简历'));
      expect(msg, contains('能力标签: 聊天、搜索'));
      expect(msg, contains('改写要求:\n更突出项目经验'));
    });

    test('空简历与空能力省略对应段落', () {
      final msg = LocalResumeGenerator.buildRegenUserMessage(
        userPrompt: '重写',
        currentResume: '   ',
        capabilities: const [],
      );
      expect(msg, isNot(contains('当前简历')));
      expect(msg, isNot(contains('能力标签')));
      expect(msg, contains('改写要求:\n重写'));
    });
  });

  group('LocalResumeGenerator.regenerate', () {
    test('空提示词直接抛 ArgumentError，不发起 LLM 调用', () async {
      await expectLater(
        LocalResumeGenerator.regenerate(_agent(), prompt: '   '),
        throwsArgumentError,
      );
    });
  });
}
