import '../../models/attachment_data.dart';
import '../../models/llm_stream_event.dart';
import '../../models/model_routing_config.dart';
import '../../models/remote_agent.dart';
import '../../models/vision/person_visual_profile.dart';
import '../../clis/shepaw/chat/chat_agent_scope.dart';
import '../local_database_service.dart';
import '../local_llm_agent_service.dart';
import '../remote_agent_service.dart';
import '../she_service.dart';
import '../token_service.dart';

/// 视觉档案构建抽象（测试可注入 stub）。
abstract class VisualProfileBuilder {
  /// 依据一位家人的参考照构建结构化视觉档案。
  Future<PersonVisualProfile> extract({
    required String personName,
    required List<AttachmentData> photos,
  });
}

/// 从参考照提取「结构化视觉档案」：复用现有视觉 LLM 链路。
///
/// 流程：
/// 1. 解析可用视觉 agent（当前执行上下文 → She → 任一本地视觉 agent）。
/// 2. `LocalLLMAgentService.chat` 携带参考照，要求 LLM 只输出 JSON。
/// 3. [parseVisualProfile] 容错解析（剥 code fence、丢弃散文、永不抛出）。
class VisualProfileExtractor implements VisualProfileBuilder {
  VisualProfileExtractor({LocalLLMAgentService? llm, RemoteAgentService? agents})
      : _llm = llm,
        _agents = agents;

  final LocalLLMAgentService? _llm;
  final RemoteAgentService? _agents;

  static const String _systemPrompt = '''
你是一位细心的家庭记录助手。根据用户提供的家人照片，抽取该家人的结构化视觉档案。
只输出一个 JSON 对象，不要输出任何其他文字或 Markdown 代码围栏。字段如下：
{
  "ageGroup": "年龄段：婴儿/幼儿/儿童/少年/青年/中年/老年",
  "hairStyle": "发型（如：短发/长发/齐刘海/丸子头）",
  "glasses": "眼镜（无/近视镜/墨镜）",
  "typicalOutfit": "常穿搭配（一段简短描述，不确定则省略）",
  "distinguishingMarks": ["明显标识：痣/胎记/耳钉/虎牙等"],
  "commonScenes": ["常见场景：客厅/公园/婴儿床等"],
  "voice": "嗓音特征（照片看不出则省略）",
  "addressTerms": ["家人对 TA 的称呼：妈妈/宝宝/老婆等"],
  "notes": "其他重要外观备注"
}
不确定的字段留空或省略，不要编造。
''';

  @override
  Future<PersonVisualProfile> extract({
    required String personName,
    required List<AttachmentData> photos,
  }) async {
    if (photos.isEmpty) return const PersonVisualProfile();

    final agent = await _resolveVisualAgent();
    if (agent == null) {
      throw StateError('未配置支持视觉的模型，无法构建视觉档案');
    }

    final message = '这是我家人「$personName」的参考照片，请按系统要求抽取其视觉档案。';
    final llm = _llm ?? LocalLLMAgentService.instance;
    final buffer = StringBuffer();
    try {
      final events = llm.chat(
        agent: agent,
        message: message,
        attachments: photos,
        systemPromptOverride: _systemPrompt,
        skipSheMemoryStack: true,
        enableUITools: false,
        includeShepawCli: false,
      );
      await for (final event in events) {
        if (event is LLMTextEvent) {
          buffer.write(event.text);
        }
      }
    } catch (_) {
      // LLM 调用失败 → 返回空档案（不抛出，调用方自行提示）
    }
    return parseVisualProfile(buffer.toString());
  }

  /// 解析当前可用的视觉 agent：
  /// 当前执行上下文 agent → She → 任一支持 image 的本地 agent。
  Future<RemoteAgent?> _resolveVisualAgent() async {
    final agents = _agents ??
        RemoteAgentService(LocalDatabaseService(), TokenService(LocalDatabaseService()));

    RemoteAgent? candidate;

    final scopedId = ChatAgentScope.agentId;
    if (scopedId.isNotEmpty) {
      candidate = await agents.getAgentById(scopedId);
      if (candidate != null && candidate.supportsModality(ModalityType.image)) {
        return candidate;
      }
    }

    candidate = await agents.getAgentById(SheService.sheId);
    if (candidate != null && candidate.supportsModality(ModalityType.image)) {
      return candidate;
    }

    final all = await agents.getAllAgents();
    for (final a in all) {
      if (a.supportsModality(ModalityType.image)) return a;
    }
    return null;
  }
}
