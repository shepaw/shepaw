import 'package:flutter/material.dart';

import '../controllers/flow/flow_executor.dart';
import '../l10n/app_localizations.dart';

/// 开跑前要问清的三件事（方案「关键设计 9」）。
class FlowStartPlan {
  const FlowStartPlan({
    required this.inputs,
    required this.bindings,
    required this.saveFirst,
  });

  /// 输入名 → 值（都是字符串，由主机按 `type` 解析）。
  final Map<String, String> inputs;

  /// 角色 → Agent id。群库流程由群成员角色自动绑定，这里为空。
  final Map<String, String> bindings;

  /// 有未保存改动时，用户选的是「先保存再跑」。
  final bool saveFirst;
}

/// 开跑表单：**独立页面**，不再是弹窗。
///
/// 弹窗把长文本挤成一行、键盘弹起来还会盖住下半张表单；换成整页 Scaffold 后
/// 输入框随内容长高（`maxLines: null`），内容多了就整页滚动。
///
/// - 头部 `inputs` 声明了什么就填什么，必填没填不能点开跑；
/// - 不在群里开跑时，**实际用到角色**的每个角色选一个 Agent（写进 `bindings`）；
///   `roles.*.default` 已经预填，不用再手选；
/// - 有未保存改动时说清楚：**开跑用的是库里的第 N 版，不是草稿**。
///
/// 返回 null 表示取消（返回键 / 取消按钮）。
Future<FlowStartPlan?> pushFlowStartScreen(
  BuildContext context, {
  required String flowName,
  required String yaml,
  required List<String> roles,
  required Map<String, String> roleDefaults,
  List<FlowInputSpec>? inputSpecs,
  required bool dirty,
  required String scope,
  required int revision,
  Map<String, String> initialInputs = const {},
  Map<String, String> initialBindings = const {},
  Future<String?> Function()? onPickAgent,
}) {
  return Navigator.of(context).push<FlowStartPlan>(
    MaterialPageRoute<FlowStartPlan>(
      fullscreenDialog: true,
      builder: (_) => FlowStartScreen(
        flowName: flowName,
        yaml: yaml,
        roles: roles,
        roleDefaults: roleDefaults,
        inputSpecs: inputSpecs,
        dirty: dirty,
        scope: scope,
        revision: revision,
        initialInputs: initialInputs,
        initialBindings: initialBindings,
        onPickAgent: onPickAgent,
      ),
    ),
  );
}

/// 开跑表单页。也可直接当普通路由用（[pushFlowStartScreen] 只是一层封装）。
class FlowStartScreen extends StatefulWidget {
  const FlowStartScreen({
    super.key,
    required this.flowName,
    required this.yaml,
    required this.roles,
    this.roleDefaults = const {},
    this.inputSpecs,
    required this.dirty,
    required this.scope,
    required this.revision,
    this.initialInputs = const {},
    this.initialBindings = const {},
    this.onPickAgent,
  });

  final String flowName;
  final String yaml;

  /// 定义里真正用到、需要绑定的角色；声明了但节点已改成 Agent 的不在这里。
  final List<String> roles;

  /// `roles.*.default`：预填进绑定，省得模板自带 Agent 还要人手选一遍。
  final Map<String, String> roleDefaults;

  /// 调用方已经解析过定义时直接给字段规格，避免再解析一遍 YAML；
  /// 不传（例如测试里单独打开本页）就自己从 [yaml] 读。
  final List<FlowInputSpec>? inputSpecs;

  final bool dirty;
  final String scope;

  /// 群库流程由群成员角色自动绑定（主机 `bindings_from_group`），页面只读显示，
  /// 不应要求用户选 Agent，更不能把用户随手选的 Agent 覆盖主机绑定。
  bool get rolesAutoBound => scope.startsWith('group:');

  final int revision;

  /// 保存成新一版后重开表单时，把上一轮填过的值带回来，别让用户重填。
  final Map<String, String> initialInputs;
  final Map<String, String> initialBindings;

  final Future<String?> Function()? onPickAgent;

  @override
  State<FlowStartScreen> createState() => _FlowStartScreenState();
}

class _FlowStartScreenState extends State<FlowStartScreen> {
  final Map<String, TextEditingController> _inputs = {};
  final Map<String, String?> _agents = {};
  late final List<FlowInputSpec> _specs;
  bool _saveFirst = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _specs = widget.inputSpecs ?? peekInputs(widget.yaml);
    for (final spec in _specs) {
      _inputs[spec.name] = TextEditingController(
        text: widget.initialInputs[spec.name] ?? spec.defaultValue ?? '',
      );
    }
    _agents.addAll(widget.initialBindings);
    for (final role in widget.roles) {
      if (_agents[role] != null) continue;
      final preset = widget.roleDefaults[role];
      if (preset != null && preset.isNotEmpty) _agents[role] = preset;
    }
  }

  @override
  void dispose() {
    for (final c in _inputs.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final l10n = AppLocalizations.of(context);
    for (final spec in _specs) {
      if (spec.required &&
          (_inputs[spec.name]?.text.trim().isNotEmpty != true)) {
        setState(() => _error = l10n.flow_startInputRequired(spec.name));
        return;
      }
    }
    // 群库流程由主机按 members_meta.roles 自动绑定，页面不拦、也不覆盖。
    if (!widget.rolesAutoBound) {
      for (final role in widget.roles) {
        if (_agents[role]?.isNotEmpty != true) {
          setState(() => _error = l10n.flow_startRoleUnbound(role));
          return;
        }
      }
    }
    Navigator.of(context).pop(FlowStartPlan(
      inputs: {
        for (final entry in _inputs.entries)
          if (entry.value.text.trim().isNotEmpty)
            entry.key: entry.value.text.trim(),
      },
      bindings: widget.rolesAutoBound
          ? const {}
          : {
              for (final entry in _agents.entries)
                if (entry.value != null) entry.key: entry.value!,
            },
      saveFirst: _saveFirst,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.flow_startTitle(widget.flowName)),
      ),
      // 底部安全区由下面的 bottomNavigationBar 处理，这里只避左右/顶部。
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 开跑确认：把「会真实调用 agent」和「演练不会」写在同一屏，
              // 别让人把两种播放按钮搞混。取消这一页不会产生任何运行。
              Card(
                key: const ValueKey('start-confirm-banner'),
                color: scheme.tertiaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.flow_startConfirmTitle,
                          style: theme.textTheme.titleSmall),
                      const SizedBox(height: 6),
                      Text(l10n.flow_startRealCallHint,
                          style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (widget.dirty) ...[
                Card(
                  color: scheme.secondaryContainer,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.info_outline),
                        title: Text(l10n.flow_startRunsSaved(widget.revision)),
                      ),
                      SwitchListTile(
                        key: const ValueKey('save-first'),
                        title: Text(l10n.flow_startSaveFirst),
                        value: _saveFirst,
                        onChanged: (v) => setState(() {
                          _saveFirst = v;
                          _error = null;
                        }),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              for (final spec in _specs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: TextField(
                    key: ValueKey('start-input-${spec.name}'),
                    controller: _inputs[spec.name],
                    keyboardType: spec.type == 'int'
                        ? TextInputType.number
                        : TextInputType.multiline,
                    textInputAction: spec.type == 'int'
                        ? TextInputAction.done
                        : TextInputAction.newline,
                    // 随内容自动长高：文本输入不再被钉死成一行。
                    minLines: 1,
                    maxLines: spec.type == 'int' ? 1 : null,
                    decoration: InputDecoration(
                      labelText:
                          spec.required ? '${spec.name} *' : spec.name,
                      alignLabelWithHint: true,
                      border: const OutlineInputBorder(),
                    ),
                    // 一改字段就撤掉上一条校验提示，别让修好了还挂着红字。
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(l10n.flow_startRoleSection,
                    style: theme.textTheme.labelLarge),
              ),
              if (widget.roles.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(l10n.flow_startNoRoles,
                      style: theme.textTheme.bodySmall),
                ),
              for (final role in widget.roles)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    key: ValueKey('start-role-$role'),
                    leading: const Icon(Icons.person_outline),
                    title: Text(role),
                    subtitle: Text(
                      widget.rolesAutoBound
                          ? l10n.flow_startRolesAutoBound
                          : (_agents[role] ?? l10n.flow_executorPickAgent),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: widget.rolesAutoBound
                        ? null
                        : const Icon(Icons.chevron_right),
                    onTap: widget.rolesAutoBound
                        ? null
                        : () async {
                            final picked = await widget.onPickAgent?.call();
                            if (picked == null || !mounted) return;
                            setState(() {
                              _agents[role] = picked;
                              _error = null;
                            });
                          },
                  ),
                ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.error),
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.common_cancel),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    key: const ValueKey('start-go'),
                    onPressed: _submit,
                    child: Text(l10n.flow_startGo),
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
