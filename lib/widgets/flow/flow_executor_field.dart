import 'package:flutter/material.dart';

import '../../controllers/flow/flow_executor.dart';
import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_models.dart';

/// 「谁来做」选择器（方案 M4）。
///
/// 主机要求 `task.role` / `task.agent` / `task.uses` 三选一，所以这里不是三个
/// 独立的框，而是一个选择器：切换模式时另外两个会被清掉（由
/// [FlowExecutor.ops] 产出 null）。
class FlowExecutorField extends StatelessWidget {
  const FlowExecutorField({
    super.key,
    required this.node,
    required this.roles,
    required this.onChanged,
    this.onPickAgent,
  });

  final FlowNode node;

  /// 定义头里的角色名（用来填下拉）。拿不到时下拉为空，仍可手输。
  final List<String> roles;

  final void Function(FlowExecutor executor) onChanged;

  /// 打开 Agent 选择器。为 null 时「Agent」退化成手输。
  final Future<String?> Function()? onPickAgent;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = FlowExecutor.of(node.fields);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.flow_executorLabel,
          style: theme.textTheme.labelLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              key: const ValueKey('exec-role'),
              label: Text(l10n.flow_executorRole),
              selected: current.mode == FlowExecutorMode.role,
              onSelected: (_) => onChanged(
                FlowExecutor.role(current.value ?? _firstRole()),
              ),
            ),
            ChoiceChip(
              key: const ValueKey('exec-agent'),
              label: Text(l10n.flow_executorAgent),
              selected: current.mode == FlowExecutorMode.agent,
              onSelected: (_) => onChanged(FlowExecutor.agent(current.value ?? '')),
            ),
            ChoiceChip(
              key: const ValueKey('exec-she'),
              label: Text(l10n.flow_executorShe),
              selected: current.mode == FlowExecutorMode.she,
              onSelected: (_) => onChanged(FlowExecutor.she),
            ),
          ],
        ),
        const SizedBox(height: 8),
        switch (current.mode) {
          FlowExecutorMode.role => _RolePicker(
              key: const ValueKey('exec-value'),
              roles: roles,
              current: current.value,
              onChanged: (v) => onChanged(FlowExecutor.role(v)),
            ),
          FlowExecutorMode.agent => ListTile(
              key: const ValueKey('exec-value'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.smart_toy_outlined),
              title: Text(
                current.value?.isNotEmpty == true
                    ? current.value!
                    : l10n.flow_executorPickAgent,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: current.value?.isNotEmpty == true
                      ? null
                      : scheme.onSurfaceVariant,
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final picked = await onPickAgent?.call();
                if (picked == null || picked.isEmpty) return;
                onChanged(FlowExecutor.agent(picked));
              },
            ),
          _ => const SizedBox.shrink(),
        },
      ],
    );
  }

  String _firstRole() => roles.isEmpty ? '' : roles.first;
}

class _RolePicker extends StatelessWidget {
  const _RolePicker({
    super.key,
    required this.roles,
    required this.current,
    required this.onChanged,
  });

  final List<String> roles;
  final String? current;
  final void Function(String value) onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final known = {...roles, if (current != null && current!.isNotEmpty) current!}
        .toList();
    return DropdownButtonFormField<String>(
      initialValue: current?.isNotEmpty == true ? current : null,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: l10n.flow_executorRole,
        isDense: true,
      ),
      items: [
        for (final role in known)
          DropdownMenuItem<String>(value: role, child: Text(role)),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}
