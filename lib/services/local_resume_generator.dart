import '../models/llm_stream_event.dart';
import '../models/remote_agent.dart';
import 'local_llm_agent_service.dart';

/// 本机 LLM 简历重写：供本地 agent 直接调用、peer 宿主代其共享的本地 agent 调用。
///
/// 纯任务路径（`skipSheMemoryStack: true` + `systemPromptOverride`），
/// 不带人格栈 / UI 工具 / CLI 工具面；调用方负责超时与结果落库。
class LocalResumeGenerator {
  LocalResumeGenerator._();

  /// 生成简历的系统提示词（纯函数，便于单测）。
  static String buildRegenSystemPrompt(RemoteAgent agent) {
    final name = agent.name.trim().isEmpty ? 'Agent' : agent.name.trim();
    return 'You are writing the self-introduction resume (简历) of an AI agent '
        'named "$name".\n'
        'Write 3-6 concise sentences in the agent\'s primary language, covering: '
        'its role/personality, what it is good at, and how a user should work with it.\n'
        'Output ONLY the resume text — no markdown headings, no preamble, no quotes.';
  }

  /// 生成简历的用户消息（纯函数）。空段落直接省略。
  static String buildRegenUserMessage({
    required String userPrompt,
    String? currentResume,
    List<String> capabilities = const [],
  }) {
    final caps = capabilities
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .join('、');
    return [
      if (currentResume != null && currentResume.trim().isNotEmpty)
        '当前简历:\n${currentResume.trim()}',
      if (caps.isNotEmpty) '能力标签: $caps',
      '改写要求:\n${userPrompt.trim()}',
    ].join('\n\n');
  }

  /// 用本机 LLM 按用户提示词重写简历，返回累积的纯文本。
  ///
  /// [prompt] 必填且非空（空提示词没有可执行语义，直接抛错）。
  /// 结果为空 / LLM 报错时抛异常；调用方自行 `.timeout()`。
  static Future<String> regenerate(
    RemoteAgent agent, {
    required String prompt,
  }) async {
    if (prompt.trim().isEmpty) {
      throw ArgumentError('prompt is required for resume regeneration');
    }
    final buf = StringBuffer();
    await for (final event in LocalLLMAgentService.instance.chat(
      agent: agent,
      message: buildRegenUserMessage(
        userPrompt: prompt,
        currentResume: agent.bio,
        capabilities: agent.capabilities,
      ),
      enableUITools: false,
      includeShepawCli: false,
      skipSheMemoryStack: true,
      systemPromptOverride: buildRegenSystemPrompt(agent),
    )) {
      switch (event) {
        case LLMTextEvent():
          buf.write(event.text);
        case LLMToolCallEvent() || LLMDoneEvent():
          break;
      }
    }
    final out = buf.toString().trim();
    if (out.isEmpty) {
      throw StateError('本地模型未返回简历内容');
    }
    return out;
  }
}
