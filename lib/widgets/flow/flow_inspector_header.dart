import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/flow/flow_outline.dart';
import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_models.dart';
import 'flow_outline_menu.dart';

/// 属性页头部：类型、id、描述、这个节点上的问题。
class FlowInspectorHeader extends StatefulWidget {
  const FlowInspectorHeader({
    super.key,
    required this.node,
    required this.readOnly,
    this.row,
    this.canRetype = false,
    this.problems = const [],
    this.onDescCommitted,
    this.onMenuChoice,
    this.onLocate,
  });

  final FlowNode node;
  final bool readOnly;
  final FlowOutlineRow? row;
  final bool canRetype;
  final List<String> problems;
  final void Function(String? desc)? onDescCommitted;
  final void Function(FlowOutlineMenuChoice choice)? onMenuChoice;
  final VoidCallback? onLocate;

  @override
  State<FlowInspectorHeader> createState() => FlowInspectorHeaderState();
}

class FlowInspectorHeaderState extends State<FlowInspectorHeader> {
  late final TextEditingController _desc;
  final FocusNode descFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _desc = TextEditingController(text: widget.node.desc ?? '');
    descFocus.addListener(_onDescFocus);
  }

  /// 保存和 Esc 都是直接把焦点移走，不会走 onTapOutside。
  /// 不在这里提交的话，描述只活在输入框里，离开这一步就丢了。
  void _onDescFocus() {
    if (!descFocus.hasFocus && !widget.readOnly) _commit();
  }

  @override
  void didUpdateWidget(covariant FlowInspectorHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (descFocus.hasFocus) return;
    final next = widget.node.desc ?? '';
    if (next != _desc.text) _desc.text = next;
  }

  @override
  void dispose() {
    descFocus.removeListener(_onDescFocus);
    _desc.dispose();
    descFocus.dispose();
    super.dispose();
  }

  void _commit() {
    final text = _desc.text.trim();
    final before = widget.node.desc ?? '';
    if (text == before) return;
    widget.onDescCommitted?.call(text.isEmpty ? null : text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final node = widget.node;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(_kindIcon(node.kind), size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                flowKindName(l10n, node.kind),
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (widget.row != null && widget.onMenuChoice != null)
              IconButton(
                key: const ValueKey('inspector-menu'),
                tooltip: l10n.flow_outlineMenu,
                icon: const Icon(Icons.more_horiz),
                onPressed: () async {
                  final choice = await showFlowOutlineMenu(
                    context,
                    row: widget.row!,
                    canRetype: widget.canRetype,
                  );
                  if (choice != null) widget.onMenuChoice!(choice);
                },
              ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Tooltip(
                message: l10n.flow_idLocked,
                child: Text(
                  node.id,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('inspector-copy-id'),
              tooltip: l10n.flow_idLocked,
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: node.id));
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(content: Text(l10n.flow_copied)),
                );
              },
            ),
          ],
        ),
        TextField(
          key: const ValueKey('inspector-desc'),
          controller: _desc,
          focusNode: descFocus,
          readOnly: widget.readOnly,
          minLines: 1,
          maxLines: 3,
          style: theme.textTheme.bodyMedium,
          decoration: InputDecoration(
            hintText: l10n.flow_descPlaceholder,
            isDense: true,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
          ),
          onEditingComplete: _commit,
          onTapOutside: (_) => _commit(),
        ),
        if (widget.problems.isNotEmpty)
          Material(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, size: 16, color: scheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.flow_nodeProblem(
                        widget.problems.length,
                        widget.problems.first,
                      ),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onErrorContainer),
                    ),
                  ),
                  if (widget.onLocate != null)
                    TextButton(
                      key: const ValueKey('inspector-locate'),
                      onPressed: widget.onLocate,
                      child: Text(l10n.flow_locate),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

IconData _kindIcon(String kind) => switch (kind) {
      'task' => Icons.task_alt,
      'seq' => Icons.format_list_numbered,
      'par' => Icons.account_tree_outlined,
      'loop' => Icons.loop,
      'if' => Icons.call_split,
      'map' => Icons.dataset_outlined,
      'gate' => Icons.front_hand_outlined,
      'set' => Icons.data_object,
      'call' => Icons.subdirectory_arrow_right,
      'plan' => Icons.auto_awesome_outlined,
      _ => Icons.circle_outlined,
    };

String flowKindName(AppLocalizations l10n, String kind) => switch (kind) {
      'task' => l10n.flow_kindNameTask,
      'seq' => l10n.flow_kindNameSeq,
      'par' => l10n.flow_kindNamePar,
      'loop' => l10n.flow_kindNameLoop,
      'if' => l10n.flow_kindNameIf,
      'map' => l10n.flow_kindNameMap,
      'gate' => l10n.flow_kindNameGate,
      'set' => l10n.flow_kindNameSet,
      'call' => l10n.flow_kindNameCall,
      'plan' => l10n.flow_kindNamePlan,
      _ => kind,
    };

String flowGroupTitle(AppLocalizations l10n, String group) => switch (group) {
      'what' => l10n.flow_groupWhat,
      'who' => l10n.flow_groupWho,
      'when' => l10n.flow_groupWhen,
      'output' => l10n.flow_groupOutput,
      'join' => l10n.flow_groupJoin,
      'until' => l10n.flow_groupUntil,
      'cond' => l10n.flow_groupCond,
      'over' => l10n.flow_groupOver,
      'ask' => l10n.flow_groupAsk,
      'show' => l10n.flow_groupShow,
      'options' => l10n.flow_groupOptions,
      'vars' => l10n.flow_groupVars,
      'flow' => l10n.flow_groupFlow,
      'where' => l10n.flow_groupWhere,
      'planWho' => l10n.flow_groupPlanWho,
      'brief' => l10n.flow_groupBrief,
      _ => l10n.flow_groupAdvanced,
    };
