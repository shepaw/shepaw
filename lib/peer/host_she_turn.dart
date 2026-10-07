import '../models/remote_agent.dart';
import '../services/she_service.dart';

/// 主机上的惜宝不在 `agents.json` 里。`agent_chat` 只认引擎实例，
/// 会回「主机上没有这个 Agent」。她的对话走储物袋回合。
bool relaysHostSheTurn(RemoteAgent agent) {
  if (!agent.isPeerAgent) return false;
  return SheService.isSheIdentity(agent.id, agent.metadata) ||
      SheService.isSheIdentity(agent.remoteAgentId, null);
}

/// 聊天框主模型用本机已添加的列表。主机惜宝不跟 Hub 的默认模型目录。
bool chatUsesRegistryMainModel(RemoteAgent agent) =>
    agent.isLocal || relaysHostSheTurn(agent);

/// 惜宝能不能开聊。主机惜宝看 Hub 名单里的 `has_main_model`，密钥不在客户端。
bool sheHasMainModel(RemoteAgent agent) {
  if (agent.isLocal) return true;
  if (!relaysHostSheTurn(agent)) return false;
  return agent.metadata['has_main_model'] == true;
}

/// 交给主机时用主机上的 id。本机行 id 和它不一致时，用远端 id。
String hostSheTurnAgentId(RemoteAgent agent) {
  final remote = agent.remoteAgentId?.trim() ?? '';
  if (remote.isNotEmpty) return remote;
  return agent.id;
}

/// 把 Hub 公布的主模型写进本机缓存。不含密钥。
void applyHostSheModelMetadata(
  Map<String, dynamic> metadata,
  Map<String, dynamic> hub,
) {
  metadata.remove('main_model_id');
  metadata.remove('llm_provider');
  metadata.remove('llm_model');
  metadata.remove('llm_api_base');
  metadata.remove('llm_api_key');
  if (hub['has_main_model'] != true) {
    metadata.remove('has_main_model');
    metadata.remove('she_model');
    metadata.remove('she_base_url');
    return;
  }
  metadata['has_main_model'] = true;
  final model = (hub['model'] as String?)?.trim() ?? '';
  final base = (hub['base_url'] as String?)?.trim() ?? '';
  if (model.isNotEmpty) {
    metadata['she_model'] = model;
  } else {
    metadata.remove('she_model');
  }
  if (base.isNotEmpty) {
    metadata['she_base_url'] = base;
  } else {
    metadata.remove('she_base_url');
  }
}

/// 用 Hub 回来的模型名和地址，对上本机列表里的一条定义。
String? hostSheRegistryModelId(
  Map<String, dynamic> metadata, {
  required Iterable<({String id, String model, String baseUrl})> models,
}) {
  final model = (metadata['she_model'] as String?)?.trim() ?? '';
  final base = (metadata['she_base_url'] as String?)?.trim() ?? '';
  if (model.isEmpty) return null;
  for (final item in models) {
    if (item.model == model && item.baseUrl == base) return item.id;
  }
  for (final item in models) {
    if (item.model == model) return item.id;
  }
  return null;
}
