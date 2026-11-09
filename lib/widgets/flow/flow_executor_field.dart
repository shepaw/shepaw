import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/flow/flow_executor.dart';
import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_models.dart';
import '../agent_list_avatar.dart';

/// 「谁来做」选择器（方案 M4）。
///
/// 主机要求 `task.role` / `task.agent` / `task.uses` 三选一，所以这里不是三个
/// 独立的框，而是一个选择器：切换模式时另外两个会被清掉（由
/// [FlowExecutor.ops] 产出 null）。
class FlowExecutorField extends StatelessWidget {
  const FlowExecutorField({
    super.key,
    required this.node,
    required this.current,
    required this.roles,
    required this.onChanged,
    this.onPickAgent,
    this.agentOf,
    this.showLabel = true,
  });

  final FlowNode node;

  /// 当前选中的执行者。必须由调用方持有状态并回传 —— 这个 widget 只负责展示，
  /// 不能从不变的 `node.fields` 里重算，否则点芯片永远不改变选中态。

  final FlowExecutor current;

  /// 定义头里的角色名（用来填下拉）。拿不到时下拉为空，仍可手输。
  final List<String> roles;

  final void Function(FlowExecutor executor) onChanged;

  /// 打开 Agent 选择器。为 null 时「Agent」退化成手输。
  final Future<String?> Function()? onPickAgent;

  /// 把主机上的 agent id 换成头像和名称。对不上就不要把 id 画出来。
  final FlowAgentFace? Function(String id)? agentOf;

  /// false：不画「谁来做」。外层分组标题已经是这句话时用。
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showLabel) ...[
          Text(
            l10n.flow_executorLabel,
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
        ],
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              key: const ValueKey('exec-role'),
              label: Text(l10n.flow_executorRole),
              selected: selected.mode == FlowExecutorMode.role,
              // 切模式时不能沿用另一个模式的值（否则角色名会被当成 Agent id）。
              onSelected: (_) => onChanged(FlowExecutor.role(
                selected.mode == FlowExecutorMode.role
                    ? (selected.value ?? _firstRole())
                    : _firstRole(),
              )),
            ),
            ChoiceChip(
              key: const ValueKey('exec-agent'),
              label: Text(l10n.flow_executorAgent),
              selected: selected.mode == FlowExecutorMode.agent,
              // 空 id 主机不收，选中态会被刷掉，选择器也就打不开。点这里直接选人。
              onSelected:
                  onPickAgent == null ? null : (_) => unawaited(_chooseAgent()),
            ),
            ChoiceChip(
              key: const ValueKey('exec-she'),
              label: Text(l10n.flow_executorShe),
              selected: selected.mode == FlowExecutorMode.she,
              onSelected: (_) => onChanged(FlowExecutor.she),
            ),
          ],
        ),
        const SizedBox(height: 8),
        switch (selected.mode) {
          FlowExecutorMode.role => _RolePicker(
              key: const ValueKey('exec-value'),
              roles: roles,
              current: selected.value,
              onChanged: (v) => onChanged(FlowExecutor.role(v)),
            ),
          FlowExecutorMode.agent => _AgentTile(
              id: selected.value ?? '',
              agentOf: agentOf,
              onPickAgent: onPickAgent,
              onChanged: onChanged,
            ),
          _ => const SizedBox.shrink(),
        },
      ],
    );
  }

  String _firstRole() => roles.isEmpty ? '' : roles.first;

  Future<void> _chooseAgent() async {
    final picked = await onPickAgent?.call();
    if (picked == null || picked.isEmpty) return;
    onChanged(FlowExecutor.agent(picked));
  }
}

class _AgentTile extends StatelessWidget {
  const _AgentTile({
    required this.id,
    required this.agentOf,
    required this.onPickAgent,
    required this.onChanged,
  });

  final String id;
  final FlowAgentFace? Function(String id)? agentOf;
  final Future<String?> Function()? onPickAgent;
  final void Function(FlowExecutor executor) onChanged;

  Future<void> _choose() async {
    final picked = await onPickAgent?.call();
    if (picked == null || picked.isEmpty) return;
    onChanged(FlowExecutor.agent(picked));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final face = id.isEmpty ? null : agentOf?.call(id);
    final name = face?.name.trim() ?? '';
    final titled = name.isNotEmpty;
    final title = id.isEmpty
        ? l10n.flow_executorPickAgent
        : (titled ? name : l10n.flow_executorAgent);
    return ListTile(
      key: const ValueKey('exec-value'),
      contentPadding: EdgeInsets.zero,
      leading: id.isEmpty
          ? const Icon(Icons.smart_toy_outlined)
          : AgentListAvatar(
              avatar: face?.avatar ?? '',
              name: titled ? name : title,
              size: 32,
            ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: id.isEmpty ? scheme.onSurfaceVariant : null,
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onPickAgent == null ? null : () => unawaited(_choose()),
    );
  }
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
    final known = {
      ...roles,
      if (current != null && current!.isNotEmpty) current!
    }.toList();
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
