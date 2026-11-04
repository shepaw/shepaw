import 'package:flutter/material.dart';

import '../../controllers/flow/flow_executor.dart';
import '../../l10n/app_localizations.dart';

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

/// 开跑对话框。
///
/// 原来列表行的「运行」不传 inputs、不确认就开跑：用了 `role` 的流程（内置的
/// review-loop 就是）开跑才报「角色没有绑定 Agent」。这里一次问清：
/// - 头部 `inputs` 声明了什么就填什么，必填没填不能点开跑；
/// - 不在群里开跑时，`roles` 每个角色选一个 Agent（写进 `bindings`）；
/// - 有未保存改动时说清楚：**开跑用的是库里的第 N 版，不是草稿**。
///
/// 返回 null 表示取消。
Future<FlowStartPlan?> showFlowStartDialog(
  BuildContext context, {
  required String flowName,
  required String yaml,
  required List<String> roles,
  required bool dirty,
  required String scope,
  required int revision,
  Future<String?> Function()? onPickAgent,
}) {
  return showDialog<FlowStartPlan>(
    context: context,
    builder: (dialogContext) => _FlowStartDialog(
      flowName: flowName,
      yaml: yaml,
      roles: roles,
      dirty: dirty,
      scope: scope,
      revision: revision,
      onPickAgent: onPickAgent,
    ),
  );
}

class _FlowStartDialog extends StatefulWidget {
  const _FlowStartDialog({
    required this.flowName,
    required this.yaml,
    required this.roles,
    required this.dirty,
    required this.scope,
    required this.revision,
    this.onPickAgent,
  });

  final String flowName;
  final String yaml;
  final List<String> roles;
  final bool dirty;
  final String scope;

  /// 群库流程由群成员角色自动绑定（主机 `bindings_from_group`），对话框只读显示，
  /// 不应要求用户选 Agent，更不能把用户随手选的 Agent 覆盖主机绑定。
  bool get rolesAutoBound => scope.startsWith('group:');

  final int revision;
  final Future<String?> Function()? onPickAgent;

  @override
  State<_FlowStartDialog> createState() => _FlowStartDialogState();
}

class _FlowStartDialogState extends State<_FlowStartDialog> {
  final Map<String, TextEditingController> _inputs = {};
  final Map<String, String?> _agents = {};
  late final List<FlowInputSpec> _specs;
  bool _saveFirst = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _specs = peekInputs(widget.yaml);
    for (final spec in _specs) {
      _inputs[spec.name] =
          TextEditingController(text: spec.defaultValue ?? '');
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
    // 群库流程由主机按 members_meta.roles 自动绑定，对话框不拦、也不覆盖。
    if (!widget.rolesAutoBound) {
      for (final role in widget.roles) {
        if (_agents[role]?.isNotEmpty != true) {
          setState(() => _error = l10n.flow_startRoleUnbound(role));
          return;
        }
      }
    }
    Navigator.pop(
      context,
      FlowStartPlan(
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      title: Text(l10n.flow_startTitle(widget.flowName)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                      onChanged: (v) => setState(() => _saveFirst = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            for (final spec in _specs)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  key: ValueKey('start-input-${spec.name}'),
                  controller: _inputs[spec.name],
                  keyboardType: spec.type == 'int'
                      ? TextInputType.number
                      : TextInputType.multiline,
                  decoration: InputDecoration(
                    labelText: spec.required
                        ? '${spec.name} *'
                        : spec.name,
                    isDense: true,
                  ),
                ),
              ),
            for (final role in widget.roles)
              ListTile(
                key: ValueKey('start-role-$role'),
                contentPadding: EdgeInsets.zero,
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
                        setState(() => _agents[role] = picked);
                      },
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          key: const ValueKey('start-go'),
          onPressed: _submit,
          child: Text(l10n.flow_startRun),
        ),
      ],
    );
  }
}
