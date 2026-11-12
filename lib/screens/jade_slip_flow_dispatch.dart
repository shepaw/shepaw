import 'package:flutter/material.dart';

import '../controllers/flow/flow_executor.dart';
import '../l10n/app_localizations.dart';
import '../models/jade_slip.dart';
import '../peer/services/hub_flow.dart';
import '../services/jade_slip_service.dart';
import '../services/local_database_service.dart';
import 'flow_run_screen.dart';
import 'flow_start_screen.dart';

/// 玉简上最多保留多少条工作流运行记录（按开跑时间取最近 N 条）。
const int kMaxJadeSlipFlowRuns = 20;

/// 把玉简字段映射成模板声明的 inputs。纯函数，方便单测。
///
/// 优先级是 `overrides > presets > 自动映射`：
/// - 显式给的非空 `overrides` 一定赢（开跑表单里人手填的值）；
/// - **空的 override 不会抹掉** preset / 自动映射的值 —— 用户清空一个输入框
///   不该让玉简上明明有的目标、约束悄悄消失；
/// - 自动映射只认 `goal` / `constraints` / `done_when` / `body` / `title` /
///   `slip_context` 这几个约定名，其余名字（包括模板没声明的名字）一律不写。
///
/// 只输出非空值。`slip_context` 把清单文本和附件袋子地址拼成一段可读文本。
Map<String, String> jadeSlipFlowInputs(
  JadeSlip slip, {
  required List<String> inputNames,
  Map<String, String> presets = const {},
  Map<String, String> overrides = const {},
  String checklistText = '',
  String attachmentUris = '',
}) {
  String auto(String name) {
    switch (name) {
      case 'goal':
        return slip.goal;
      case 'constraints':
        return slip.constraints;
      case 'done_when':
        return slip.doneWhen;
      case 'body':
        return slip.body;
      case 'title':
        return slip.title;
      case 'slip_context':
        return _slipContext(slip, checklistText, attachmentUris);
      default:
        return '';
    }
  }

  final out = <String, String>{};
  for (final raw in inputNames) {
    final name = raw.trim();
    if (name.isEmpty) continue;
    for (final candidate in <String?>[
      overrides[name],
      presets[name],
      auto(name),
    ]) {
      final value = candidate?.trim() ?? '';
      if (value.isEmpty) continue;
      out[name] = value;
      break;
    }
  }
  return out;
}

String _slipContext(
  JadeSlip slip,
  String checklistText,
  String attachmentUris,
) {
  final lines = <String>['玉简「${slip.title.trim()}」'];
  final goal = slip.goal.trim();
  final constraints = slip.constraints.trim();
  final doneWhen = slip.doneWhen.trim();
  final body = slip.body.trim();
  if (goal.isNotEmpty) lines.add('目标：$goal');
  if (constraints.isNotEmpty) lines.add('约束：$constraints');
  if (doneWhen.isNotEmpty) lines.add('完成标准：$doneWhen');
  if (body.isNotEmpty) lines.add('备注：$body');
  final checklist = checklistText.trim();
  if (checklist.isNotEmpty) {
    lines.add('清单：');
    lines.add(checklist);
  }
  final uris = attachmentUris.trim();
  if (uris.isNotEmpty) {
    lines.add('附件：');
    lines.add(uris);
  }
  return lines.join('\n');
}

/// 按 runId 取并集；同一 runId 的终态优先于 running（主机回写可能比 App 本地
/// 记录晚到），最后只留按开跑时间排序的最近 [kMaxJadeSlipFlowRuns] 条。
List<JadeSlipFlowRun> mergeJadeSlipFlowRuns(
  List<JadeSlipFlowRun> existing,
  JadeSlipFlowRun next,
) {
  final byId = <String, JadeSlipFlowRun>{};
  final order = <String, int>{};
  var index = 0;
  for (final run in <JadeSlipFlowRun>[...existing, next]) {
    if (run.runId.isEmpty) continue;
    order.putIfAbsent(run.runId, () => index++);
    final prev = byId[run.runId];
    if (prev == null ||
        (!prev.isTerminal && run.isTerminal) ||
        (prev.isTerminal == run.isTerminal &&
            run.startedAt >= prev.startedAt)) {
      byId[run.runId] = run;
    }
  }
  final all = byId.values.toList()
    ..sort((a, b) {
      final byTime = a.startedAt.compareTo(b.startedAt);
      return byTime != 0
          ? byTime
          : (order[a.runId] ?? 0).compareTo(order[b.runId] ?? 0);
    });
  if (all.length <= kMaxJadeSlipFlowRuns) return all;
  return all.sublist(all.length - kMaxJadeSlipFlowRuns);
}

/// 从流程库里挑一个模板给玉简绑定。返回 null 表示取消。
///
/// 只列 `lib` 和已知的群库（从 [current] 的 scope 或 [groupScopes] 推出来，
/// 不凭空造 group id）。重新选中同一个模板时保留预设输入和角色绑定，但版本
/// 一律回到「取最新」—— 钉住的那一版被删掉后，重选要能恢复。
Future<JadeSlipFlowBinding?> showJadeSlipFlowTemplatePicker(
  BuildContext context, {
  required JadeSlip slip,
  JadeSlipFlowBinding? current,
  HubFlow? client,
  List<String> groupScopes = const [],
}) {
  return showDialog<JadeSlipFlowBinding>(
    context: context,
    builder: (_) => _JadeSlipFlowTemplatePicker(
      slip: slip,
      current: current,
      client: client ?? HubFlow(),
      groupScopes: groupScopes,
    ),
  );
}

/// 派发一条「执行者 = 工作流」的玉简。返回是否已经开跑。
///
/// 与 Agent 路径完全分开：不挑 Agent、不选会话、不写 `sourceChannelId`。
/// [confirmed] 表示确认弹层已经点过；输入或角色还缺时仍会打开开跑表单让
/// 人补齐。所有主机调用都单独兜底，离线 / 主机报错只出一条 snackbar。
Future<bool> dispatchJadeSlipFlow(
  BuildContext context,
  JadeSlip slip, {
  JadeSlipItem? focusItem,
  required bool confirmed,
  HubFlow? client,
}) async {
  final l10n = AppLocalizations.of(context);
  final flow = client ?? HubFlow();

  void snack(String text, {String? actionLabel, VoidCallback? onAction}) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        action: actionLabel != null && onAction != null
            ? SnackBarAction(label: actionLabel, onPressed: onAction)
            : null,
      ),
    );
  }

  final binding = slip.flowBinding;
  if (binding == null || binding.name.trim().isEmpty) {
    snack(l10n.jadeSlip_flowMissing);
    return false;
  }

  String host = '';
  try {
    host = await flow.activeHost();
  } catch (_) {
    // 连不上主机 / 读不到登录态都按离线处理。
  }
  if (host.isEmpty) {
    snack(l10n.jadeSlip_flowOffline);
    return false;
  }

  ({int revision, String yaml, List<String>? requiredRoles})? fetched;
  try {
    fetched = await flow.get(
      host,
      binding.name,
      scope: binding.scope,
      revision: binding.revision,
    );
  } catch (_) {
    // 帧解析 / 连接异常：跟「取不到模板」同一套提示。
  }
  if (fetched == null || fetched.yaml.trim().isEmpty) {
    snack(
      l10n.jadeSlip_flowMissing,
      actionLabel: l10n.jadeSlip_flowPick,
      onAction: () async {
        if (!context.mounted) return;
        final picked = await showJadeSlipFlowTemplatePicker(
          context,
          slip: slip,
          current: binding,
          client: flow,
        );
        if (picked == null) return;
        try {
          // 写新副本，别把别人刚改过的玉简整份覆盖回去。
          final fresh = await JadeSlipService.instance.getById(slip.id) ?? slip;
          await JadeSlipService.instance
              .update(fresh.copyWith(flowBinding: picked));
        } catch (_) {
          // 保存失败不静默吞掉：提示再选一次，别让人以为已经换好了。
          snack(l10n.jadeSlip_flowMissing);
        }
      },
    );
    return false;
  }

  late final FlowRunFormData form;
  try {
    form = FlowRunFormData.parse(
      fetched.yaml,
      requiredRoles: fetched.requiredRoles,
    );
  } catch (_) {
    snack(l10n.jadeSlip_flowStartFailed('yaml'));
    return false;
  }

  // 清单文本：单项入口只带那一项，顶栏入口带整份清单。附件地址优先用
  // 袋子里的 v3 形式，拼不出来就退回模型上的 v2 地址。
  final scopedItems = focusItem != null
      ? <JadeSlipItem>[focusItem]
      : slip.items;
  final checklistText = <String>[
    for (final item in scopedItems)
      '- [${item.state.mark}] ${item.text}',
  ].join('\n');
  final attachmentLines = <String>[];
  for (final attachment in slip.attachments) {
    var uri = attachment.uri;
    try {
      final resolved =
          await JadeSlipService.instance.attachmentUri(slip, attachment);
      if (resolved.trim().isNotEmpty) uri = resolved.trim();
    } catch (_) {
      // 地址拼不出来不影响开跑。
    }
    attachmentLines.add('- ${attachment.name}: $uri');
  }

  final autoInputs = jadeSlipFlowInputs(
    slip,
    inputNames: <String>[for (final spec in form.inputs) spec.name],
    presets: binding.inputs,
    checklistText: checklistText,
    attachmentUris: attachmentLines.join('\n'),
  );
  // 模板自己的 default 也是有效输入：开跑表单会预填它，直接开跑时同样算数。
  final initialInputs = <String, String>{...autoInputs};
  for (final spec in form.inputs) {
    final current = initialInputs[spec.name]?.trim() ?? '';
    final fallback = spec.defaultValue?.trim() ?? '';
    if (current.isEmpty && fallback.isNotEmpty) {
      initialInputs[spec.name] = fallback;
    }
  }
  final missingInputs = <String>[
    for (final spec in form.inputs)
      if (spec.required && (initialInputs[spec.name] ?? '').trim().isEmpty)
        spec.name,
  ];

  // 群库流程由主机按群成员角色自动绑定（FlowStartScreen.rolesAutoBound）。
  // 非群库必须有显式绑定；模板的 roles.*.default 也算已经绑好。
  final rolesAutoBound = binding.scope.startsWith('group:');
  final initialBindings = <String, String>{
    for (final entry in form.roleDefaults.entries)
      if (entry.key.trim().isNotEmpty && entry.value.trim().isNotEmpty)
        entry.key.trim(): entry.value.trim(),
    for (final entry in binding.bindings.entries)
      if (entry.key.trim().isNotEmpty && entry.value.trim().isNotEmpty)
        entry.key.trim(): entry.value.trim(),
  };
  final missingRoles = rolesAutoBound
      ? <String>[]
      : <String>[
          for (final role in form.roles)
            if ((initialBindings[role] ?? '').trim().isEmpty) role,
        ];

  var inputs = initialInputs;
  var bindings = rolesAutoBound
      ? <String, String>{}
      : <String, String>{
          for (final entry in initialBindings.entries)
            if (entry.value.trim().isNotEmpty)
              entry.key: entry.value.trim(),
        };
  final complete = missingInputs.isEmpty && missingRoles.isEmpty;
  if (!complete || !confirmed) {
    if (!context.mounted) return false;
    final plan = await pushFlowStartScreen(
      context,
      flowName: binding.name,
      yaml: fetched.yaml,
      roles: form.roles,
      roleDefaults: form.roleDefaults,
      inputSpecs: form.inputs,
      dirty: false,
      scope: binding.scope,
      revision: fetched.revision,
      initialInputs: initialInputs,
      initialBindings: initialBindings,
    );
    if (plan == null) return false;
    // 表单里人手填的值覆盖预设 / 自动映射。
    inputs = plan.inputs;
    bindings = plan.bindings;
  }

  // 钉住表单据以生成的那一版，避免别人在这期间存了新版导致两边不一致；
  // binding.revision 为空时用刚取回的最新版作为这次运行的版本。
  final runRevision =
      binding.revision ?? (fetched.revision > 0 ? fetched.revision : null);
  final origin = <String, dynamic>{
    'kind': 'slip',
    'slip_id': slip.id,
    'device_id': slip.deviceId,
  };
  late final FlowCall result;
  try {
    result = await flow.start(
      host,
      scope: binding.scope,
      name: binding.name,
      revision: runRevision,
      inputs: <String, dynamic>{...inputs},
      bindings: bindings.isEmpty ? null : <String, dynamic>{...bindings},
      origin: origin,
    );
  } catch (_) {
    snack(l10n.jadeSlip_flowOffline);
    return false;
  }
  if (!result.reachable) {
    snack(l10n.jadeSlip_flowOffline);
    return false;
  }
  // 响应帧里 run_id 类型不对时也不许把派发炸掉（老主机 / 手工改坏的帧）。
  String runId = '';
  try {
    runId = result.runId?.trim() ?? '';
  } catch (_) {}
  if (!result.ok || runId.isEmpty) {
    snack(l10n.jadeSlip_flowStartFailed(result.error ?? ''));
    return false;
  }
  // 旧主机不会给 origin_ack：运行照常开，只是终态不会回写玉简。
  if (!result.originAck) {
    snack(l10n.jadeSlip_flowOldHost);
  }

  try {
    // 开跑到落盘之间主机可能已经回写了终态事件，先读新副本再合并。
    JadeSlip fresh = slip;
    try {
      fresh = await JadeSlipService.instance.getById(slip.id) ?? slip;
    } catch (_) {
      // 读不到就用派发时那份，不把运行记录弄丢。
    }
    await JadeSlipService.instance.update(
      fresh.copyWith(
        flowRuns: mergeJadeSlipFlowRuns(
          fresh.flowRuns,
          JadeSlipFlowRun(
            runId: runId,
            startedAt: DateTime.now().millisecondsSinceEpoch,
            status: 'running',
            hostId: host,
          ),
        ),
        status: JadeSlipStatus.inProgress,
        flowStatus: '',
      ),
    );
  } catch (_) {
    // 运行已经开起来了，本地写失败不该把派发判成失败。
  }

  if (!context.mounted) return true;
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => FlowRunScreen(
      peerId: host,
      runId: runId,
      title: _runTitle(inputs, slip, binding.name),
      client: flow,
      sourceSlipId: slip.id,
      sourceSlipTitle: slip.title,
    ),
  ));
  return true;
}

String _runTitle(
  Map<String, String> inputs,
  JadeSlip slip,
  String fallback,
) {
  for (final key in const ['title', 'goal', 'task']) {
    final value = inputs[key]?.trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  final title = slip.title.trim();
  return title.isNotEmpty ? title : fallback;
}

// ---------------------------------------------------------------------------
// 模板选择弹层
// ---------------------------------------------------------------------------

class _TemplateEntry {
  const _TemplateEntry({
    required this.scope,
    required this.name,
    required this.revision,
    required this.description,
  });

  final String scope;
  final String name;
  final int revision;
  final String description;

  /// 弹层行 / ValueKey 用的名字。公共库不带 scope，群库带上以免同名撞键。
  String get displayKey => scope == 'lib' ? name : '$scope/$name';
}

class _JadeSlipFlowTemplatePicker extends StatefulWidget {
  const _JadeSlipFlowTemplatePicker({
    required this.slip,
    required this.current,
    required this.client,
    required this.groupScopes,
  });

  final JadeSlip slip;
  final JadeSlipFlowBinding? current;
  final HubFlow client;
  final List<String> groupScopes;

  @override
  State<_JadeSlipFlowTemplatePicker> createState() =>
      _JadeSlipFlowTemplatePickerState();
}

class _JadeSlipFlowTemplatePickerState
    extends State<_JadeSlipFlowTemplatePicker> {
  bool _loading = true;
  bool _offline = false;
  List<_TemplateEntry> _templates = const [];
  String _host = '';
  final Map<String, Future<List<String>>> _inputNames = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<String> get _scopes {
    final out = <String>['lib'];
    void add(String raw) {
      final scope = raw.trim();
      if (scope.startsWith('group:') && !out.contains(scope)) out.add(scope);
    }

    add(widget.slip.flowBinding?.scope ?? '');
    add(widget.current?.scope ?? '');
    for (final scope in widget.groupScopes) {
      add(scope);
    }
    return out;
  }

  /// 玉简本身不带群 id，可见群从本地会话表推（和 She 的群概览同一份数据）。
  /// 只列用户已经能看到的一级群，不凭空造 group id；读库失败只退回显式传入的
  /// 群 scope，不影响公共库模板。
  Future<List<String>> _visibleGroupScopes() async {
    try {
      final channels = await LocalDatabaseService().getAllChannels();
      return <String>[
        for (final channel in channels)
          if (channel.isGroup && channel.parentGroupId == null)
            'group:${channel.id}',
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _offline = false;
      });
    }
    String host = '';
    try {
      host = await widget.client.activeHost();
    } catch (_) {
      // 读不到登录态按离线处理。
    }
    if (!mounted) return;
    if (host.isEmpty) {
      setState(() {
        _loading = false;
        _offline = true;
        _templates = const [];
      });
      return;
    }

    final entries = <_TemplateEntry>[];
    final seen = <String>{};
    var reachable = false;
    // 公共库 + 玉简所属群 + 本机可见的一级群，去重后逐个拉模板。
    final scopes = <String>['lib'];
    void addScope(String raw) {
      final scope = raw.trim();
      if (scope.isNotEmpty && !scopes.contains(scope)) scopes.add(scope);
    }

    for (final scope in _scopes) {
      addScope(scope);
    }
    for (final scope in await _visibleGroupScopes()) {
      addScope(scope);
    }
    for (final scope in scopes) {
      try {
        final flows = await widget.client.list(host, scope: scope);
        if (flows == null) continue;
        reachable = true;
        for (final summary in flows) {
          final name = summary.name.trim();
          if (name.isEmpty) continue;
          final entry = _TemplateEntry(
            scope: scope,
            name: name,
            revision: summary.latest,
            description: summary.description?.trim() ?? '',
          );
          if (!seen.add(entry.displayKey)) continue;
          entries.add(entry);
        }
      } catch (_) {
        // 某个库取不到不影响其它库；一个都没取到才算离线。
      }
    }
    if (!mounted) return;
    setState(() {
      _host = host;
      _templates = entries;
      _offline = !reachable;
      _loading = false;
    });
  }

  /// 选中行时顺手取一次定义，把声明的 inputs 名字列出来。取不到就只显示
  /// 模板名 / 说明，绝不让「列个模板」被网络问题卡住。
  Future<List<String>> _inputsOf(_TemplateEntry entry) =>
      _inputNames.putIfAbsent(entry.displayKey, () async {
        try {
          final fetched = await widget.client.get(
            _host,
            entry.name,
            scope: entry.scope,
          );
          if (fetched == null) return const <String>[];
          return <String>[
            for (final spec in peekInputs(fetched.yaml))
              if (spec.name.trim().isNotEmpty) spec.name.trim(),
          ];
        } catch (_) {
          return const <String>[];
        }
      });

  void _pick(_TemplateEntry entry) {
    final current = widget.current;
    final same = current != null &&
        current.scope == entry.scope &&
        current.name == entry.name;
    Navigator.of(context).pop(
      JadeSlipFlowBinding(
        scope: entry.scope,
        name: entry.name,
        // 重选一律回到最新版：钉住的那一版被删掉时这样能恢复。
        revision: null,
        inputs: same ? current.inputs : const {},
        bindings: same ? current.bindings : const {},
        inputFrom: same ? current.inputFrom : const {},
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.jadeSlip_flowPick),
      content: SizedBox(
        width: 420,
        child: _body(l10n, theme),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.common_cancel),
        ),
        if (_offline)
          TextButton(
            onPressed: _load,
            child: Text(l10n.common_retry),
          ),
      ],
    );
  }

  Widget _body(AppLocalizations l10n, ThemeData theme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_offline) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(l10n.jadeSlip_flowOffline),
      );
    }
    if (_templates.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(l10n.jadeSlip_flowNoTemplates),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 380),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final entry in _templates) _row(entry, l10n, theme),
        ],
      ),
    );
  }

  Widget _row(_TemplateEntry entry, AppLocalizations l10n, ThemeData theme) {
    final revision = entry.revision > 0
        ? l10n.jadeSlip_flowVersion(entry.revision)
        : l10n.jadeSlip_flowRevisionLatest;
    return ListTile(
      key: ValueKey('slip-flow-template-${entry.displayKey}'),
      title: Text(entry.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entry.scope != 'lib') Text('${l10n.jadeSlip_flowLibraryGroup} · ${entry.scope}'),
          if (entry.description.isNotEmpty) Text(entry.description),
          Text(revision, style: theme.textTheme.bodySmall),
          FutureBuilder<List<String>>(
            future: _inputsOf(entry),
            builder: (context, snapshot) {
              final names = snapshot.data ?? const <String>[];
              if (names.isEmpty) return const SizedBox.shrink();
              return Text(
                '${l10n.jadeSlip_flowInput}: ${names.join('、')}',
                style: theme.textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              );
            },
          ),
        ],
      ),
      onTap: () => _pick(entry),
    );
  }
}
