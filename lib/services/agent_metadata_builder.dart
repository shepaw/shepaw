import '../models/model_definition.dart';
import 'model_registry.dart';

/// 主模型配置在 agent metadata 中的三种状态。
enum MainModelState {
  /// 选中（或已存储）的主模型能在 registry 中解析到定义。
  resolved,

  /// 存储过主模型配置（`main_model_id` 或 legacy `llm_provider`），但都
  /// 解析不到定义 —— 悬空。典型成因：模型定义被删了。
  dangling,

  /// 本来就没有配置主模型（如 She、新建但未选模型的 agent）。
  unset,
}

/// 按 [id] 查模型定义；默认走 [ModelRegistry.instance]。
typedef ModelLookup = ModelDefinition? Function(String id);

/// 组装 agent metadata 中「主模型」相关的键。
///
/// 原地修改 [metadata]（调用方应传入 `Map.from(agent.metadata)` 副本）。
///
/// 语义：
/// - [selectedMainModelId] 能在 registry 中解析到 → 写入 `main_model_id` /
///   `llm_provider`，并清掉冗余的 legacy `llm_*` 字段。
/// - 未选中但 metadata 里存着可解析的 `main_model_id`（例如刚把同一个 id
///   重新加回 registry）→ 回落到该 id，按上一行处理。
/// - 未选中、且存储过主模型配置但解析不到 → 悬空：**保持原样**。
/// - 未选中、且完全查不到主模型痕迹 → 清空主模型键（对这类 agent 全是
///   no-op，等价于「什么都不做」）。
///
/// 悬空时保留 `llm_provider` 是修复数据损坏的关键：它是
/// `RemoteAgent.isLocal` 的唯一判据，删掉会把本地 agent 静默改写成
/// 「远端 ACP agent」；保留 `main_model_id` 则让模型被重新添加后能自动恢复。
///
/// 由此得到一条不变量：**只要 agent 当前是本地（有 `llm_provider`）或存过
/// `main_model_id`，一次未选中主模型的保存就绝不会剥掉它的模型配置**。
/// 详情页没有「清空主模型」入口，`selectedMainModelId == null` 只可能来自
/// 「解析失败」，所以这条不变量不会挡住任何合法操作。
///
/// 只处理主模型键。技能 / 工具模型 / CLI 命令 / scenario_models 与模型选择
/// 无关，由调用方独立写入，不要塞回这里。
///
/// 返回 [MainModelState] 与悬空时的展示用标识（原始 id / 模型名）。
({MainModelState state, String? danglingRef}) buildLlmMetadata(
  Map<String, dynamic> metadata, {
  required String? selectedMainModelId,
  ModelLookup? lookupModel,
}) {
  final resolve = lookupModel ?? ModelRegistry.instance.getById;

  final storedId = _nonEmpty(metadata['main_model_id'] as String?);

  // 未选中时回落到已存储的 id：只有解析得到定义才算「选中的主模型」。
  final candidateId = selectedMainModelId ?? storedId;
  if (candidateId != null) {
    final def = resolve(candidateId);
    if (def != null) {
      metadata['main_model_id'] = candidateId;
      final provider = def.route.provider;
      // llm_provider 仅为 isLocalAgent() 哨兵存在，完整配置在调用时经
      // ModelRegistry 按 id 查。
      metadata['llm_provider'] =
          (provider != null && provider.isNotEmpty) ? provider : 'openai';
      // 清掉可能残留的冗余字段，避免干扰 ModelRegistry 查找。
      metadata.remove('llm_model');
      metadata.remove('llm_api_base');
      metadata.remove('llm_api_key');
      return (state: MainModelState.resolved, danglingRef: null);
    }
  }

  // 悬空：保留 main_model_id / llm_provider（含 llm_* legacy 回退字段）。
  // 不只看 main_model_id —— 老数据的 llm_provider 同样是本地 agent 的判据，
  // 定义被删后一并落入这条路径。
  if (storedId != null) {
    return (state: MainModelState.dangling, danglingRef: storedId);
  }
  if (metadata['llm_provider'] != null) {
    return (
      state: MainModelState.dangling,
      // 只有 legacy 字段时用模型名兜底展示（真实数据里通常没有 llm_model，
      // 此时调用方不弹提示，但配置照样保住了）。
      danglingRef: _nonEmpty(metadata['llm_model'] as String?),
    );
  }

  _clearMainModel(metadata);
  return (state: MainModelState.unset, danglingRef: null);
}

void _clearMainModel(Map<String, dynamic> metadata) {
  metadata.remove('llm_provider');
  metadata.remove('main_model_id');
  metadata.remove('llm_model');
  metadata.remove('llm_api_base');
  metadata.remove('llm_api_key');
}

String? _nonEmpty(String? value) =>
    (value == null || value.isEmpty) ? null : value;
