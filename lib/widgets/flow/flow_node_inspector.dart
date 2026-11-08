import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/flow/flow_executor.dart';
import '../../controllers/flow/flow_field_catalog.dart';
import '../../controllers/flow/flow_outline.dart';
import '../../controllers/flow/flow_references.dart';
import '../../l10n/app_localizations.dart';
import '../../models/remote_agent.dart';
import '../../peer/host_she_turn.dart';
import '../../peer/models/flow_field_schema.dart';
import '../../peer/models/flow_models.dart';
import '../../peer/services/peer_agent_client_service.dart';
import '../../service_locator.dart' show getIt;
import '../../services/local_database_service.dart';
import 'flow_executor_field.dart';
import 'flow_field_editors.dart';
import 'flow_inspector_header.dart';
import 'flow_outline_menu.dart';

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
  LocalDatabaseService database,
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
  final hubId =
      agentId == null ? '' : hubAgentIdFromRaw(agentId, peerId: peerId);

  final List<RemoteAgent> agents;
  try {
    agents = await database.getAllRemoteAgents();
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
          ? hubAgentIdFromRaw(a.remoteAgentId!, peerId: peerId)
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
  bool modelsAllowManual = false,
  bool modesAllowManual = false,
}) {
  // 每个字段独立判断：这一路没有结果（请求失败且没有缓存）就只把这一路
  // 退成手输，不能因为另一路成功就把用户彻底锁死。
  // A8-7：缓存里是空列表、主机又没答上来时，用户连模板都填不了；「成功但
  // 为空」与「拉取失败」都要给手输入口。
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
      allowManual: models == null || models.models.isEmpty || modelsAllowManual,
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
      allowManual: modes == null || modes.modes.isEmpty || modesAllowManual,
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
  LocalDatabaseService? db,
}) async {
  // A8-10：数据库从组合根取，不在这里直接 new。测试可以用 [db] 注入替身。
  final database = db ??
      (getIt.isRegistered<LocalDatabaseService>()
          ? getIt<LocalDatabaseService>()
          : null);
  if (database == null) return _manualOnlyBundle;
  // 没固定 agent（unset / role 无 default）：不碰网络和主机，直接允许手输。
  final target = await _resolveAgentTarget(executor, peerId, roles, database);
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
  // A8-7：没答上来的那一路只是退回缓存，不代表主机确认过「没有可选项」；
  // 空缓存 + 刷新失败时仍要允许用户手输模板变量。
  return _bundleFrom(
    models,
    modes,
    modelsAllowManual: modelOut == null || !modelOut.completed,
    modesAllowManual: modeOut == null || !modeOut.completed,
  );
}


/// 节点属性：嵌在右侧上下文面板里，改动直接交给控制器。
///
/// 不再有「应用」按钮。下拉 / 开关立刻提交；文本在失焦、Enter 或控制器的
/// 防抖里提交。非法值留在输入框里标红，不发给主机。
class FlowNodeInspector extends StatefulWidget {
  const FlowNodeInspector({
    super.key,
    required this.node,
    required this.schema,
    this.onFieldChanged,
    this.onExecutorChanged,
    this.onDescChanged,
    this.onMenuChoice,
    this.row,
    this.canRetype = false,
    this.readOnly = false,
    this.rehearsalLocked = false,
    this.roles = const [],
    this.onPickAgent,
    this.agentOf,
    this.tree = const [],
    this.yaml = '',
    this.flowRefs = const [],
    this.peerId = '',
    this.choiceLoader,
    this.problems = const [],
    this.problemIsError = true,
    this.rejections = const {},
    this.flashField,
    this.showInvalidBanner = false,
    this.focusNonce = 0,
    this.discardNonce = 0,
    this.onValidity,
  });

  final FlowNode node;
  final FlowSchema schema;
  final void Function(String path, Object? value, {required bool immediate})?
      onFieldChanged;
  final void Function(Map<String, Object?> ops)? onExecutorChanged;
  final void Function(String? desc)? onDescChanged;
  final void Function(FlowOutlineMenuChoice choice)? onMenuChoice;
  final FlowOutlineRow? row;
  final bool canRetype;
  final bool readOnly;
  final bool rehearsalLocked;
  final List<String> roles;
  final Future<String?> Function()? onPickAgent;

  /// 把 `task.agent` 的 id 换成头像和名称。
  final FlowAgentFace? Function(String id)? agentOf;
  final List<FlowNode> tree;
  final String yaml;
  final List<String> flowRefs;
  final String peerId;
  final FlowChoiceLoader? choiceLoader;
  final List<String> problems;
  final bool problemIsError;
  final Map<String, String> rejections;
  final String? flashField;
  final bool showInvalidBanner;
  final int focusNonce;
  final int discardNonce;
  final ValueChanged<bool>? onValidity;

  @override
  State<FlowNodeInspector> createState() => FlowNodeInspectorState();
}

class FlowNodeInspectorState extends State<FlowNodeInspector> {
  final GlobalKey<FlowInspectorHeaderState> _headerKey = GlobalKey();
  final GlobalKey _flashKey = GlobalKey();
  int _advancedEpoch = 0;
  bool _advancedOpen = false;
  late List<FlowFieldSpec> _specs;
  late FlowExecutor _executor;

  FlowModelChoices _modelChoices = FlowModelChoices.empty;
  FlowModelChoices _modeChoices = FlowModelChoices.empty;
  int _choicesToken = 0;
  int _choiceSeed = 0;

  /// 换执行者后，节点对象还是旧的，模型 / 模式要先按本地清空来画。
  Object? _modelSeed;
  Object? _modeSeed;
  bool _modelSeeded = false;
  bool _modeSeeded = false;

  /// 上次从节点上读到的模型 / 模式。和种子不同、又和这个值不同，说明是
  /// 撤销或主机回包，应该丢掉本地种子，改跟节点走。
  Object? _seenModel;
  Object? _seenMode;
  final Set<String> _invalid = {};

  bool get _locked => widget.readOnly || widget.rehearsalLocked;
  bool get _isTask => widget.node.kind == 'task';
  bool get hasBlockingInvalid => _invalid.isNotEmpty;

  void discardInvalid() {
    if (_invalid.isEmpty) return;
    setState(() => _invalid.clear());
  }

  void focusFirst() => _headerKey.currentState?.descFocus.requestFocus();

  @override
  void initState() {
    super.initState();
    _executor = FlowExecutor.of(widget.node.fields);
    _specs = _collect(widget.node);
    _seenModel = flowFieldValue(widget.node.fields, 'task.model');
    _seenMode = flowFieldValue(widget.node.fields, 'task.mode');
    if (_isTask) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshChoices(_executor);
      });
    }
    _advancedOpen = _flashInAdvanced;
    _scheduleFlashScroll();
  }

  bool get _flashInAdvanced {
    final field = widget.flashField;
    if (field == null) return false;
    for (final spec in _specs) {
      if (spec.path == field && spec.group == 'advanced') return true;
      if (spec.path == field &&
          !FlowFieldCatalog.groupsFor(widget.node.kind).contains(spec.group)) {
        return true;
      }
    }
    return false;
  }

  void _scheduleFlashScroll() {
    if (widget.flashField == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _flashKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 250),
        alignment: 0.2,
      );
    });
  }

  @override
  void didUpdateWidget(covariant FlowNodeInspector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.discardNonce != oldWidget.discardNonce) {
      _invalid.clear();
      widget.onValidity?.call(false);
    }
    if (widget.flashField != oldWidget.flashField) {
      if (_flashInAdvanced && !_advancedOpen) {
        _advancedOpen = true;
        _advancedEpoch++;
      }
      _scheduleFlashScroll();
    }
    if (widget.focusNonce != oldWidget.focusNonce) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) focusFirst();
      });
    }
    if (oldWidget.node.id != widget.node.id) {
      _executor = FlowExecutor.of(widget.node.fields);
      _specs = _collect(widget.node);
      _invalid.clear();
      _modelSeeded = false;
      _modeSeeded = false;
      _seenModel = flowFieldValue(widget.node.fields, 'task.model');
      _seenMode = flowFieldValue(widget.node.fields, 'task.mode');
      _choicesToken++;
      if (_isTask) _refreshChoices(_executor);
      return;
    }
    _specs = _collect(widget.node);
    _syncChoiceSeed('task.model', model: true);
    _syncChoiceSeed('task.mode', model: false);
    final fromNode = FlowExecutor.of(widget.node.fields);
    final previous = FlowExecutor.of(oldWidget.node.fields);
    // 只在节点上的执行者变了时才跟上（撤销、主机回包）。父级因别的通知
    // 重建时字段还是旧的，不能把刚选中、还没写回去的 Agent 清掉。
    if (!_sameExecutor(previous, fromNode) &&
        !_sameExecutor(fromNode, _executor)) {
      _executor = fromNode;
    }
  }

  List<FlowFieldSpec> _collect(FlowNode node) => [
        for (final spec in FlowFieldCatalog.specsFor(node.kind, widget.schema))
          if (!_isTask ||
              (spec.path != 'task.role' &&
                  spec.path != 'task.agent' &&
                  spec.path != 'task.uses'))
            spec,
      ];

  /// 节点上的模型 / 模式变了（撤销、主机规范化），不再用换执行者时的本地种子。
  void _syncChoiceSeed(String path, {required bool model}) {
    final fromNode = flowFieldValue(widget.node.fields, path);
    final seen = model ? _seenModel : _seenMode;
    if (_same(fromNode, seen)) return;
    if (model) {
      _seenModel = fromNode;
      _modelSeeded = false;
    } else {
      _seenMode = fromNode;
      _modeSeeded = false;
    }
    _choiceSeed++;
  }

  bool _sameExecutor(FlowExecutor a, FlowExecutor b) =>
      a.mode == b.mode && a.value == b.value;

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

  bool _isTemplateValue(Object? value) =>
      value is String && value.trimLeft().startsWith('{{');

  void _onExecutorChanged(FlowExecutor executor) {
    final changed =
        executor.mode != _executor.mode || executor.value != _executor.value;
    final previousModel = _modelSeeded
        ? _modelSeed
        : flowFieldValue(widget.node.fields, 'task.model');
    final previousMode = _modeSeeded
        ? _modeSeed
        : flowFieldValue(widget.node.fields, 'task.mode');
    setState(() => _executor = executor);
    if (!changed || !_isTask) {
      widget.onExecutorChanged?.call(executor.ops());
      return;
    }
    final ops = executor.ops();
    var cleared = false;
    if (!_isTemplateValue(previousModel)) {
      ops['task.model'] = null;
      cleared = previousModel != null;
      _modelSeed = null;
      _modelSeeded = true;
    } else {
      _modelSeed = previousModel;
      _modelSeeded = true;
    }
    if (!_isTemplateValue(previousMode)) {
      ops['task.mode'] = null;
      cleared = cleared || previousMode != null;
      _modeSeed = null;
      _modeSeeded = true;
    } else {
      _modeSeed = previousMode;
      _modeSeeded = true;
    }
    setState(() {
      _modelChoices = const FlowModelChoices(loading: true);
      _modeChoices = const FlowModelChoices(loading: true);
      _choiceSeed++;
    });
    _refreshChoices(executor);
    widget.onExecutorChanged?.call(ops);
    if (!cleared || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(
      content: Text(AppLocalizations.of(context).flow_modelCleared),
      duration: const Duration(seconds: 2),
    ));
  }

  void _commit(FlowFieldSpec spec, Object? value, {required bool immediate}) {
    if (_locked) return;
    final before = flowFieldValue(widget.node.fields, spec.path);
    // 和节点上一样（包括「本来就是空的」）：不是一次失败的编辑，别标红，
    // 也别发出去。空列表上点「添加」会先交出 null，不能因此拦住切节点。
    if (_same(before, value)) {
      if (_invalid.remove(spec.path)) {
        setState(() {});
        widget.onValidity?.call(_invalid.isNotEmpty);
      }
      return;
    }
    if (!isFlowFieldValueValid(spec, value)) {
      setState(() => _invalid.add(spec.path));
      widget.onValidity?.call(true);
      return;
    }
    setState(() => _invalid.remove(spec.path));
    widget.onValidity?.call(_invalid.isNotEmpty);
    widget.onFieldChanged?.call(spec.path, value, immediate: immediate);
  }

  bool _same(Object? a, Object? b) {
    if (a == null || b == null) return a == b;
    if (a is Map || a is List || b is Map || b is List) {
      return jsonEncode(a) == jsonEncode(b);
    }
    return a.toString() == b.toString();
  }

  bool _immediate(FlowFieldSpec spec) => switch (spec.shape) {
        FlowFieldShape.string ||
        FlowFieldShape.text ||
        FlowFieldShape.int ||
        FlowFieldShape.intOrInput ||
        FlowFieldShape.duration ||
        FlowFieldShape.cond ||
        FlowFieldShape.flowRef ||
        FlowFieldShape.listOf ||
        FlowFieldShape.mapOf ||
        FlowFieldShape.outputMap =>
          false,
        _ => true,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final node = widget.node;
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final refCandidates = FlowReferences.of(
      tree: widget.tree,
      currentNodeId: node.id,
      yaml: widget.yaml,
    );
    final varRoots = FlowReferences.tree(
      tree: widget.tree,
      currentNodeId: node.id,
      yaml: widget.yaml,
    );
    final intInputs = [
      for (final spec in peekInputs(widget.yaml))
        if (spec.type == 'int') spec.name,
    ];
    final groups = FlowFieldCatalog.groupsFor(node.kind);
    final byGroup = <String, List<FlowFieldSpec>>{};
    for (final spec in _specs) {
      final group = groups.contains(spec.group) ? spec.group : 'advanced';
      byGroup.putIfAbsent(group, () => []).add(spec);
    }

    final children = <Widget>[
      if (widget.rehearsalLocked)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            l10n.flow_rehearsalReadOnly,
            key: const ValueKey('inspector-rehearsal-lock'),
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary),
          ),
        ),
      if (widget.showInvalidBanner)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            l10n.flow_invalidPending(_invalid.length),
            key: const ValueKey('inspector-invalid-banner'),
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ),
      FlowInspectorHeader(
        key: _headerKey,
        node: node,
        readOnly: _locked,
        row: widget.row,
        canRetype: widget.canRetype,
        problems: widget.problems,
        problemIsError: widget.problemIsError,
        onDescCommitted: _locked ? null : widget.onDescChanged,
        onMenuChoice: _locked ? null : widget.onMenuChoice,
      ),
      const SizedBox(height: 12),
      if (widget.readOnly)
        for (final group in groups)
          if (byGroup[group]?.isNotEmpty ?? false)
            _readOnlyGroup(group, byGroup[group]!, zh, l10n, theme)
          else
            const SizedBox.shrink()
      else
        for (final group in groups)
          if (group == 'advanced')
            _advanced(byGroup[group] ?? const [], refCandidates, intInputs,
                varRoots, l10n, theme)
          else if (byGroup[group]?.isNotEmpty ?? false || (_isTask && group == 'who'))
            _group(
              group,
              byGroup[group] ?? const [],
              refCandidates,
              intInputs,
              varRoots,
              l10n,
              theme,
            ),
      if (node.kind == 'if')
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(l10n.flow_ifBranchHint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      if (node.kind == 'seq')
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(l10n.flow_seqHint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _group(
    String group,
    List<FlowFieldSpec> specs,
    List<String> refCandidates,
    List<String> intInputs,
    List<FlowVarNode> varRoots,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            flowGroupTitle(l10n, group),
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (_isTask && group == 'who')
            FlowExecutorField(
              node: widget.node,
              current: _executor,
              roles: widget.roles,
              onPickAgent: _locked ? null : widget.onPickAgent,
              agentOf: widget.agentOf,
              onChanged: _locked ? (_) {} : _onExecutorChanged,
            ),
          ..._groupFields(group, specs, refCandidates, intInputs, varRoots),
        ],
      ),
    );
  }

  Widget _advanced(
    List<FlowFieldSpec> specs,
    List<String> refCandidates,
    List<String> intInputs,
    List<FlowVarNode> varRoots,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    if (specs.isEmpty) return const SizedBox.shrink();
    final forceOpen = specs.any((spec) => spec.path == widget.flashField);
    final summary = _advancedSummary(specs);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ExpansionTile(
        key: ValueKey('inspector-advanced-$_advancedEpoch'),
        initiallyExpanded: _advancedOpen || forceOpen,
        tilePadding: EdgeInsets.zero,
        title: Text(l10n.flow_groupAdvanced,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            )),
        subtitle: summary.isEmpty
            ? null
            : Text(summary,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        children: [
          for (final spec in specs) ...[
            _fieldEditor(spec, refCandidates, intInputs, varRoots),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  String _advancedSummary(List<FlowFieldSpec> specs) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final parts = <String>[];
    for (final spec in specs) {
      final value = flowFieldValue(widget.node.fields, spec.path);
      if (value == null) continue;
      if (spec.defaultValue != null && value.toString() == spec.defaultValue.toString()) {
        continue;
      }
      final shown = spec.shape == FlowFieldShape.enumOf && value is String
          ? spec.optionLabel(value, zh)
          : value.toString();
      parts.add('${spec.label(zh)} $shown');
    }
    return parts.join(' · ');
  }

  List<Widget> _groupFields(
    String group,
    List<FlowFieldSpec> specs,
    List<String> refCandidates,
    List<String> intInputs,
    List<FlowVarNode> varRoots,
  ) {
    final model = specs.where((spec) => spec.shape == FlowFieldShape.modelRef);
    final mode = specs.where((spec) => spec.shape == FlowFieldShape.modeRef);
    final rest = [
      for (final spec in specs)
        if (spec.shape != FlowFieldShape.modelRef &&
            spec.shape != FlowFieldShape.modeRef)
          spec,
    ];
    return [
      if (group == 'who' && model.isNotEmpty && mode.isNotEmpty)
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 440) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final spec in [...model, ...mode]) ...[
                    _fieldEditor(spec, refCandidates, intInputs, varRoots),
                    const SizedBox(height: 12),
                  ],
                ],
              );
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _fieldEditor(
                        model.first, refCandidates, intInputs, varRoots),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _fieldEditor(
                        mode.first, refCandidates, intInputs, varRoots),
                  ),
                ],
              ),
            );
          },
        )
      else
        for (final spec in [...model, ...mode]) ...[
          _fieldEditor(spec, refCandidates, intInputs, varRoots),
          const SizedBox(height: 12),
        ],
      for (final spec in rest) ...[
        _fieldEditor(spec, refCandidates, intInputs, varRoots),
        const SizedBox(height: 12),
      ],
    ];
  }

  /// 这些输入框里可以写 `{{ }}`。名字、类型、时长不算。
  bool _offersVarSuggest(FlowFieldSpec spec) {
    if (FlowReferences.supports(spec.path)) return true;
    switch (spec.shape) {
      case FlowFieldShape.intOrInput:
      case FlowFieldShape.mapOf:
      case FlowFieldShape.listOf:
      case FlowFieldShape.modelRef:
      case FlowFieldShape.modeRef:
        return true;
      default:
        return false;
    }
  }

  Widget _fieldEditor(
    FlowFieldSpec spec,
    List<String> refCandidates,
    List<String> intInputs,
    List<FlowVarNode> varRoots,
  ) {
    final isModel = spec.shape == FlowFieldShape.modelRef;
    final isMode = spec.shape == FlowFieldShape.modeRef;
    final current = isModel && _modelSeeded
        ? _modelSeed
        : isMode && _modeSeeded
            ? _modeSeed
            : flowFieldValue(widget.node.fields, spec.path);
    final executorMissing =
        _isTask && _executor.mode == FlowExecutorMode.unset && (isModel || isMode);
    final flashing = widget.flashField == spec.path;
    final key = ValueKey(
      '${widget.node.id}/${spec.path}${isModel || isMode ? '/$_choiceSeed' : ''}',
    );
    return AnimatedContainer(
      key: flashing ? _flashKey : null,
      duration: const Duration(milliseconds: 200),
      decoration: flashing
          ? BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      padding: flashing ? const EdgeInsets.all(4) : EdgeInsets.zero,
      child: FlowFieldEditor(
        key: key,
        spec: spec,
        current: current,
        enabled: !_locked && !executorMissing,
        errorText: widget.rejections[spec.path] ??
            (executorMissing
                ? AppLocalizations.of(context).flow_pickExecutorFirst
                : null),
        refCandidates:
            FlowReferences.supports(spec.path) ? refCandidates : const [],
        varRoots: _offersVarSuggest(spec) ? varRoots : const [],
        intInputNames:
            spec.shape == FlowFieldShape.intOrInput ? intInputs : const [],
        flowRefChoices:
            spec.shape == FlowFieldShape.flowRef ? widget.flowRefs : const [],
        choices: isModel ? _modelChoices : (isMode ? _modeChoices : null),
        onChanged: (value) => _commit(spec, value, immediate: _immediate(spec)),
        onCommitted: (value, {required bool immediate}) =>
            _commit(spec, value, immediate: immediate),
      ),
    );
  }

  Widget _readOnlyGroup(
    String group,
    List<FlowFieldSpec> specs,
    bool zh,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(flowGroupTitle(l10n, group),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              )),
          const SizedBox(height: 6),
          for (final spec in specs)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _readOnlyValue(spec, zh, theme),
            ),
        ],
      ),
    );
  }

  Widget _readOnlyValue(FlowFieldSpec spec, bool zh, ThemeData theme) {
    final value = flowFieldValue(widget.node.fields, spec.path);
    final text = _display(spec, value, zh);
    final long = spec.shape == FlowFieldShape.text && text.length > 80;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${spec.label(zh)}：$text', style: theme.textTheme.bodyMedium),
        if (long)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
              },
              child: Text(AppLocalizations.of(context).flow_copied),
            ),
          ),
      ],
    );
  }

  String _display(FlowFieldSpec spec, Object? value, bool zh) {
    if (value == null) {
      if (spec.defaultValue != null) {
        final raw = spec.defaultValue.toString();
        final human = spec.shape == FlowFieldShape.enumOf
            ? spec.optionLabel(raw, zh)
            : raw;
        return zh ? '默认（$human）' : 'Default ($human)';
      }
      return '—';
    }
    if (spec.shape == FlowFieldShape.enumOf && value is String) {
      return spec.optionLabel(value, zh);
    }
    if (value is Map || value is List) return jsonEncode(value);
    return value.toString();
  }
}
