import '../../models/attachment_data.dart';
import '../../models/model_routing_config.dart';
import '../../models/remote_agent.dart';
import '../../models/vision/person_visual_profile.dart';
import '../../clis/shepaw/chat/chat_agent_scope.dart';
import '../local_database_service.dart';
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

/// 视觉档案不再在这台设备上抽取。仍会确认有没有视觉模型，避免静默当成没配置。
class VisualProfileExtractor implements VisualProfileBuilder {
  VisualProfileExtractor({RemoteAgentService? agents}) : _agents = agents;

  final RemoteAgentService? _agents;

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
    return const PersonVisualProfile();
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
