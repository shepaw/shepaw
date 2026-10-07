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

/// 主机名单同步会整行重写 metadata。本机选的主模型不在名单里，要留下。
const peerLocalModelKeys = <String>[
  'main_model_id',
  'llm_provider',
  'llm_model',
  'llm_api_base',
  'llm_api_key',
];

void keepPeerLocalModelChoice(
  Map<String, dynamic> metadata,
  Map<String, dynamic>? existing,
) {
  if (existing == null) return;
  for (final key in peerLocalModelKeys) {
    if (!existing.containsKey(key)) continue;
    final value = existing[key];
    if (value == null) continue;
    metadata[key] = value;
  }
}

/// 交给主机时用主机上的 id。本机行 id 和它不一致时，用远端 id。
String hostSheTurnAgentId(RemoteAgent agent) {
  final remote = agent.remoteAgentId?.trim() ?? '';
  if (remote.isNotEmpty) return remote;
  return agent.id;
}

/// 主机惜宝在编辑页选中的主模型。Hub 自己没有这份地址和密钥。
class HostSheEndpoint {
  const HostSheEndpoint({
    required this.model,
    required this.baseUrl,
    required this.apiKey,
  });

  final String model;
  final String baseUrl;
  final String apiKey;

  bool get isReady => baseUrl.trim().isNotEmpty;
}

HostSheEndpoint? hostSheEndpointFromMetadata(
  Map<String, dynamic> metadata, {
  required HostSheEndpoint? Function(String id) lookup,
}) {
  final id = (metadata['main_model_id'] as String?)?.trim() ?? '';
  if (id.isEmpty) return null;
  return lookup(id);
}
