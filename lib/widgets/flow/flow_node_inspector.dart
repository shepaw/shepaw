import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../controllers/flow/flow_edit_ops.dart';
import '../../controllers/flow/flow_executor.dart';
import '../../controllers/flow/flow_field_catalog.dart';
import '../../controllers/flow/flow_references.dart';
import '../../l10n/app_localizations.dart';
import '../../models/remote_agent.dart';
import '../../peer/host_she_turn.dart';
import '../../peer/models/flow_field_schema.dart';
import '../../peer/models/flow_models.dart';
import '../../peer/services/peer_agent_client_service.dart';
import '../../services/local_database_service.dart';
import 'flow_executor_field.dart';
import 'flow_field_editors.dart';
import 'flow_node_tree.dart';

/// 把本机行 id / 旧格式 `peeragent_<peer>_<remote>` / `agent:` 前缀剥成 Hub 侧
/// 的 agent id。`task.agent` 里可能还留着老值。
String _stripToHubId(String raw, String peerId) {
  var id = raw.trim();
  if (id.startsWith('agent:')) id = id.substring('agent:'.length);
  final prefix = 'peeragent_${peerId}_';
  if (prefix.isNotEmpty && id.startsWith(prefix)) {
    id = id.substring(prefix.length);
  }
  return id;
}

const FlowChoiceBundle _manualOnlyBundle = FlowChoiceBundle(
  models: FlowModelChoices(allowManual: true),
  modes: FlowModelChoices(allowManual: true),
);

/// 解析当前执行者 → 该去哪个 agent 上拉模型 / 模式。null 表示运行时才绑定
/// （role 没 default、没选执行者），那种情况只能手输模板变量。
Future<({String localAgentId, String remoteAgentId})?> _resolveAgentTarget(
  FlowExecutor executor,
  String peerId,
  Map<String, dynamic> roles,
) async {
  String? agentId;
  var she = false;
  switch (executor.mode) {
    case FlowExecutorMode.agent:
      agentId = executor.value;
    case FlowExecutorMode.she:
      she = true;
    case FlowExecutorMode.role:
      final r = roles[executor.value];
      agentId = r is Map ? r['default']?.toString() : null;
    case FlowExecutorMode.unset:
      return null;
  }
  if (!she && (agentId == null || agentId.isEmpty)) return null;
  final hubId = agentId == null ? '' : _stripToHubId(agentId, peerId);

  final List<RemoteAgent> agents;
  try {
    agents = await LocalDatabaseService().getAllRemoteAgents();
  } catch (_) {
    return null;
  }
  for (final a in agents) {
    if (a.sourcePeerId != peerId) continue;
    if (she) {
      if (relaysHostSheTurn(a)) {
        return (localAgentId: a.id, remoteAgentId: hostSheTurnAgentId(a));
      }
      continue;
    }
    if (isPeerAgentRowId(a.id, peerId, hubId) || a.id == hubId) {
      final remote = (a.remoteAgentId?.trim().isNotEmpty ?? false)
          ? _stripToHubId(a.remoteAgentId!, peerId)
          : hubId;
      return (localAgentId: a.id, remoteAgentId: remote);
    }
  }
  return null;
}

FlowChoiceBundle _bundleFrom(
  PeerModelsList? models,
  PeerModesList? modes, {
  bool loading = false,
}) {
  // 每个字段独立判断：这一路没有结果（请求失败且没有缓存）就只把这一路
  // 退成手输，不能因为另一路成功就把用户彻底锁死。
  return FlowChoiceBundle(
    models: FlowModelChoices(
      options: [
        for (final m in models?.models ?? const <PeerAgentModel>[])
          FlowModelChoice(
              value: m.value,
              displayName: m.displayName,
              description: m.description),
      ],
      current: models?.current,
      switchable: models?.switchable ?? true,
      loading: loading,
      allowManual: models == null,
    ),
    modes: FlowModelChoices(
      options: [
        for (final m in modes?.modes ?? const <PeerAgentMode>[])
          FlowModelChoice(
              value: m.value,
              displayName: m.displayName,
              description: m.description),
      ],
      current: modes?.current,
      loading: loading,
      allowManual: modes == null,
    ),
  );
}

/// 单个请求失败只影响自己：失败返回 null，另一个照常返回结果。
Future<({PeerModelsList list, bool completed})?> _fetchModelsSafe(
  PeerAgentClientService client,
  String peerId,
  String remoteAgentId,
) async {
  try {
    return await client.fetchModelsResult(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
    );
  } catch (_) {
    return null;
  }
}

Future<({PeerModesList list, bool completed})?> _fetchModesSafe(
  PeerAgentClientService client,
  String peerId,
  String remoteAgentId,
) async {
  try {
    return await client.fetchModesResult(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
    );
  } catch (_) {
    return null;
  }
}

/// 生产用的 [FlowChoiceLoader]：先读缓存立刻显示，再向主机刷新。
///
/// 全程包在 try/catch 里 —— 离线、主机不应答、或者测试里没初始化数据库时都能
/// 安静退化成「手动输入」，绝不让检查器因为拉不到列表而崩掉。
Future<FlowChoiceBundle> defaultFlowChoiceLoader(
  FlowExecutor executor, {
  required String peerId,
  required Map<String, dynamic> roles,
  required void Function(FlowChoiceBundle cached) onCached,
}) async {
  // 没固定 agent（unset / role 无 default）：不碰数据库和网络，直接允许手输。
  final target = await _resolveAgentTarget(executor, peerId, roles);
  if (target == null) return _manualOnlyBundle;

  final client = PeerAgentClientService.instance;
  PeerModelsList? cachedModels;
  PeerModesList? cachedModes;
  // 两个缓存读互不依赖，一起等；一个失败不影响另一个。
  await Future.wait([
    () async {
      try {
        cachedModels = await client.cachedModels(target.localAgentId);
      } catch (_) {}
    }(),
    () async {
      try {
        cachedModes = await client.cachedModes(target.localAgentId);
      } catch (_) {}
    }(),
  ]);
  if (cachedModels != null && cachedModels!.models.isNotEmpty) {
    onCached(_bundleFrom(cachedModels, cachedModes, loading: true));
  }

  // 模型 / 模式两个请求并发；各自的 try/catch 在 [_fetchModelsSafe] /
  // [_fetchModesSafe] 里，一个抛异常不会把另一个的成功结果一起丢掉。
  final fetched = await Future.wait<Object?>([
    _fetchModelsSafe(client, peerId, target.remoteAgentId),
    _fetchModesSafe(client, peerId, target.remoteAgentId),
  ]);
  final modelOut = fetched[0] as ({PeerModelsList list, bool completed})?;
  final modeOut = fetched[1] as ({PeerModesList list, bool completed})?;

  // completed == true 就采信主机返回的列表，**哪怕是空列表**：空是实现
  // 「这个 agent 没有可选项」的合法答案，不能拿旧缓存把已删掉的模型又画出来。
  // 只有没答上来（completed == false / 请求失败）才退回缓存。
  final models = modelOut == null
      ? cachedModels
      : (modelOut.completed ? modelOut.list : cachedModels);
  final modes = modeOut == null
      ? cachedModes
      : (modeOut.completed ? modeOut.list : cachedModes);
  if (models == null && modes == null) return _manualOnlyBundle;
  return _bundleFrom(models, modes);
}

/// 节点检查器：底部抽屉表单。
///
/// 字段表由 [FlowFieldCatalog] 把主机 schema 和客户端补充表合并而来（标量 +
/// 列表 / 映射 / 条件 / 结构化输出）。当前值取自节点的 `fields`，改动只产出
/// `set` 操作，真正改 YAML 的是 Hub。
class FlowNodeInspector extends StatefulWidget {
  const FlowNodeInspector({
    super.key,
    required this.node,
    required this.schema,
    required this.onApply,
    required this.onDelete,
    required this.onWrap,
    required this.onUnwrap,
    required this.onAddAfter,
    this.roles = const [],
    this.onPickAgent,
    this.tree = const [],
    this.yaml = '',
    this.flowRefs = const [],
    this.peerId = '',
    this.choiceLoader,
  });

  final FlowNode node;
  final FlowSchema schema;

  /// 改动的字段（点分路径 → 新值；null 表示清掉）。
  final void Function(Map<String, Object?> changes) onApply;
  final VoidCallback onDelete;

  /// `par` / `loop`。
  final void Function(String kind) onWrap;
  final VoidCallback onUnwrap;
  final VoidCallback onAddAfter;

  final List<String> roles;
  final Future<String?> Function()? onPickAgent;

  /// 当前节点树和草稿（生成「插入引用」候选和 int 输入列表）。
  final List<FlowNode> tree;
  final String yaml;

  /// 同 scope 的流程库引用候选（`call.flow` 用）。
  final List<String> flowRefs;

  /// 这个流程所在的主机 peer id：拉模型 / 模式列表时要发给它。
  final String peerId;

  /// 拉候选的实现，测试里换成假的（默认走 [defaultFlowChoiceLoader]）。
  final FlowChoiceLoader? choiceLoader;

  @override
  State<FlowNodeInspector> createState() => _FlowNodeInspectorState();
}

class _FlowNodeInspectorState extends State<FlowNodeInspector> {
  late final List<FlowFieldSpec> _specs;
  late final Map<String, Object?> _original;
  final Map<String, Object?> _values = {};

  /// 执行者的选中状态由检查器持有（[FlowExecutorField] 是无状态的展示）。
  /// 为 null 表示用户没动过：那就一个字段都别发，免得把现有的清掉。
  late FlowExecutor _executor;
  bool _executorDirty = false;

  // 模型 / 模式下拉的异步候选。
  FlowModelChoices _modelChoices = FlowModelChoices.empty;
  FlowModelChoices _modeChoices = FlowModelChoices.empty;
  int _choicesToken = 0;
  int _choiceSeed = 0;
  Object? _modelSeedValue;
  Object? _modeSeedValue;

  bool get _isTask => widget.node.kind == 'task';

  @override
  void initState() {
    super.initState();
    _executor = FlowExecutor.of(widget.node.fields);
    _executorDirty = false;
    // `task.role` / `task.agent` / `task.uses` 都交给「谁来做」选择器，不再单独
    // 出文本框（否则会和选择器在同一批里发出两个互相冲突的执行者）。
    _specs = [
      for (final spec
          in FlowFieldCatalog.specsFor(widget.node.kind, widget.schema))
        if (!_isTask ||
            (spec.path != 'task.role' &&
                spec.path != 'task.agent' &&
                spec.path != 'task.uses'))
          spec,
    ];
    for (final spec in _specs) {
      _values[spec.path] = flowFieldValue(widget.node.fields, spec.path);
    }
    _original = Map<String, Object?>.from(_values);
    _modelSeedValue = _original['task.model'];
    _modeSeedValue = _original['task.mode'];
    if (_isTask) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshChoices(_executor);
      });
    }
  }

  /// 按当前执行者重新拉候选。缓存先显示，刷新结果随后覆盖；用 token 挡住
  /// 换 agent 后迟到的旧回包。
  void _refreshChoices(FlowExecutor executor) {
    final token = ++_choicesToken;
    final loader = widget.choiceLoader ?? defaultFlowChoiceLoader;
    unawaited(() async {
      try {
        final bundle = await loader(
          executor,
          peerId: widget.peerId,
          roles: FlowHeaderPeek.raw(widget.yaml, 'roles'),
          onCached: (cached) {
            if (mounted && token == _choicesToken) {
              setState(() {
                _modelChoices = cached.models;
                _modeChoices = cached.modes;
              });
            }
          },
        );
        if (mounted && token == _choicesToken) {
          setState(() {
            _modelChoices = bundle.models;
            _modeChoices = bundle.modes;
          });
        }
      } catch (_) {
        if (mounted && token == _choicesToken) {
          setState(() {
            _modelChoices = const FlowModelChoices(allowManual: true);
            _modeChoices = const FlowModelChoices(allowManual: true);
          });
        }
      }
    }());
  }

  /// 换执行者：不同 agent 的模型 / 模式 id 不通用，清掉已选的具体值再重新拉。
  ///
  /// 模板值（`{{ inputs.model }}`）和具体 agent 无关，保留 —— 换 agent 不该
  /// 把用户写的引用清掉，也不该在 Apply 时发一条 `set(null)`。
  void _onExecutorChanged(FlowExecutor executor) {
    final changed =
        executor.mode != _executor.mode || executor.value != _executor.value;
    setState(() {
      _executor = executor;
      _executorDirty = true;
    });
    if (!changed || !_isTask) return;
    var cleared = false;
    final keepModel = _isTemplateValue(_values['task.model']);
    final keepMode = _isTemplateValue(_values['task.mode']);
    if (!keepModel) {
      if (_values['task.model'] != null) cleared = true;
      _values['task.model'] = null;
      _modelSeedValue = null;
    } else {
      _modelSeedValue = _values['task.model'];
    }
    if (!keepMode) {
      if (_values['task.mode'] != null) cleared = true;
      _values['task.mode'] = null;
      _modeSeedValue = null;
    } else {
      _modeSeedValue = _values['task.mode'];
    }
    // 换 agent 后旧列表立刻作废：不等异步结果回来，就不能再让用户看到
    // 上一个 agent 的模型 / 模式（id 不通用，选了也会被主机拒）。
    setState(() {
      _modelChoices = const FlowModelChoices(loading: true);
      _modeChoices = const FlowModelChoices(loading: true);
      _choiceSeed++;
    });
    _refreshChoices(executor);
    if (!cleared) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger != null) {
      messenger.showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context).flow_modelCleared),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  /// `{{ ... }}` 模板值：运行时才绑定，跟具体 agent 无关。
  bool _isTemplateValue(Object? value) =>
      value is String && value.trimLeft().startsWith('{{');

  /// 和打开时不一样的字段。映射 / 列表按 JSON 比，不然内容相同也会被判成改动。
  Map<String, Object?> _changes() {
    final changes = <String, Object?>{};
    if (_isTask && _executorDirty) {
      changes.addAll(_executor.ops());
    }
    for (final entry in _values.entries) {
      final before = _original[entry.key];
      if (_same(before, entry.value)) continue;
      // 必填字段被清空：不发 null（主机解析会失败），界面上标红让用户填回去。
      final spec = _specs.where((s) => s.path == entry.key).firstOrNull;
      // 必填字段被清空、或编辑器标红的非法值：不发（主机解析会失败），界面上
      // 标红让用户填回去。
      if (spec == null || !isFlowFieldValueValid(spec, entry.value)) continue;
      changes[entry.key] = entry.value;
    }
    return changes;
  }

  String _fingerprint(Object? value) {
    if (value is Map || value is List) return jsonEncode(value);
    return value?.toString() ?? '';
  }

  bool _same(Object? a, Object? b) {
    if (a == null || b == null) return a == b;
    if (a is Map || a is List || b is Map || b is List) {
      return jsonEncode(a) == jsonEncode(b);
    }
    return a.toString() == b.toString();
  }

  Widget _fieldEditor(
    FlowFieldSpec spec,
    List<String> refCandidates,
    List<String> intInputs,
  ) {
    final isModel = spec.shape == FlowFieldShape.modelRef;
    final isMode = spec.shape == FlowFieldShape.modeRef;
    // model / mode 的种子在换 agent 后会变（清空），并靠 _choiceSeed 换 key
    // 强制重新播种；其余字段仍用打开时的值派生 key。
    final current = isModel
        ? _modelSeedValue
        : (isMode ? _modeSeedValue : _original[spec.path]);
    final key = ValueKey(
        'field-${spec.path}-${isModel || isMode ? 'g$_choiceSeed-' : ''}${_fingerprint(_original[spec.path])}');
    return FlowFieldEditor(
      key: key,
      spec: spec,
      current: current,
      refCandidates:
          FlowReferences.supports(spec.path) ? refCandidates : const [],
      intInputNames:
          spec.shape == FlowFieldShape.intOrInput ? intInputs : const [],
      flowRefChoices:
          spec.shape == FlowFieldShape.flowRef ? widget.flowRefs : const [],
      choices: isModel ? _modelChoices : (isMode ? _modeChoices : null),
      onChanged: (value) => _values[spec.path] = value,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final node = widget.node;
    final isContainer = FlowStepDefaults.isContainer(node.kind);
    final refCandidates = FlowReferences.of(
      tree: widget.tree,
      currentNodeId: node.id,
      yaml: widget.yaml,
    );
    final intInputs = [
      for (final spec in peekInputs(widget.yaml))
        if (spec.type == 'int') spec.name,
    ];

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 12,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(flowKindTitle(l10n, node),
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              if (_isTask)
                FlowExecutorField(
                  node: node,
                  current: _executor,
                  roles: widget.roles,
                  onPickAgent: widget.onPickAgent,
                  onChanged: _onExecutorChanged,
                ),
              for (final spec in _specs)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: _fieldEditor(spec, refCandidates, intInputs),
                ),
              const SizedBox(height: 8),
              FilledButton(
                key: const ValueKey('inspector-apply'),
                onPressed: () => widget.onApply(_changes()),
                child: Text(l10n.flow_inspectorApply),
              ),
              const Divider(height: 24),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton(
                    onPressed: widget.onAddAfter,
                    child: Text(l10n.flow_addAfter),
                  ),
                  OutlinedButton(
                    onPressed: () => widget.onWrap('par'),
                    child: Text(l10n.flow_wrapPar),
                  ),
                  OutlinedButton(
                    onPressed: () => widget.onWrap('loop'),
                    child: Text(l10n.flow_wrapLoop),
                  ),
                  if (isContainer)
                    OutlinedButton(
                      onPressed: widget.onUnwrap,
                      child: Text(l10n.flow_unwrap),
                    ),
                  OutlinedButton(
                    onPressed: widget.onDelete,
                    child: Text(l10n.flow_inspectorDelete),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
