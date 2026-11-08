import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_models.dart';

/// 工作流节点树的嵌套卡片渲染（方案 C.2）。不画连线，块结构自上而下。
///
/// 设计预览和运行视图共用：没有运行信息时 `status` 为空，卡片不叠状态。
class FlowNodeTree extends StatelessWidget {
  const FlowNodeTree({
    super.key,
    required this.nodes,
    this.onTapNode,
    this.onOpenSession,
    this.onAnswerGate,
    this.badgeFor,
    this.onLongPressNode,
    this.selectedIds = const {},
    this.selectionMode = false,
  });

  final List<FlowNode> nodes;
  final void Function(FlowNode node)? onTapNode;

  /// 点节点卡片上的会话入口：打开这条 agent 会话的私聊。
  final void Function(FlowNode node)? onOpenSession;

  /// 关卡卡片上点了某个选项。
  final void Function(FlowNode node, String choice)? onAnswerGate;

  /// 节点标题旁的小标记（差异里的"新增""有改动"），返回空就不画。
  final (String, Color)? Function(FlowNode node)? badgeFor;

  /// 长按选中（C.3 的点选）：选中后可以对着它说话，让群主改。
  final void Function(FlowNode node)? onLongPressNode;

  /// 已选中的节点 id。
  final Set<String> selectedIds;

  /// 选择模式：每行左边一个复选框，点击由调用方切换选中。
  final bool selectionMode;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < nodes.length; i++) ...[
          if (i > 0) const _Connector(),
          FlowNodeCard(
            node: nodes[i],
            onTapNode: onTapNode,
            onOpenSession: onOpenSession,
            onAnswerGate: onAnswerGate,
            badgeFor: badgeFor,
            onLongPressNode: onLongPressNode,
            selected: selectedIds.contains(nodes[i].id),
            selectedIds: selectedIds,
            selectionMode: selectionMode,
          ),
        ],
      ],
    );
  }
}

class _Connector extends StatelessWidget {
  const _Connector();

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 1.5,
          height: 10,
          color: Theme.of(context).dividerColor,
        ),
      );
}

/// 标题里的人话：`loop` 写轮次，`par` 写"并行"。翻译不了就原样显示 kind。
String flowKindTitle(AppLocalizations l10n, FlowNode node) {
  switch (node.kind) {
    case 'seq':
      return l10n.flow_kindSeq(node.id);
    case 'par':
      return l10n.flow_kindPar(node.children.length);
    case 'loop':
      final rounds = node.rounds;
      return rounds == null
          ? l10n.flow_kindLoop(node.id)
          : l10n.flow_kindLoopRound(rounds);
    case 'if':
      return l10n.flow_kindIf(node.id);
    case 'map':
      return l10n.flow_kindMap(node.id);
    case 'plan':
      return l10n.flow_kindPlan(node.id);
    case 'call':
      return l10n.flow_kindCall(node.id);
    case 'gate':
      return l10n.flow_kindGate(node.id);
    case 'set':
      return l10n.flow_kindSet(node.id);
    case 'task':
      return node.id;
    default:
      return l10n.flow_kindOther(node.kind, node.id);
  }
}

String flowStatusLabel(AppLocalizations l10n, FlowNodeStatus status) =>
    switch (status) {
      FlowNodeStatus.pending => l10n.flow_nodePending,
      FlowNodeStatus.running => l10n.flow_nodeRunning,
      FlowNodeStatus.done => l10n.flow_nodeDone,
      FlowNodeStatus.halted => l10n.flow_nodeHalted,
      FlowNodeStatus.failed => l10n.flow_nodeFailed,
      FlowNodeStatus.skipped => l10n.flow_nodeSkipped,
      FlowNodeStatus.cancelled => l10n.flow_nodeCancelled,
      FlowNodeStatus.waitingUser => l10n.flow_nodeWaitingUser,
    };

Color flowStatusColor(FlowNodeStatus status) => switch (status) {
      FlowNodeStatus.pending => Colors.grey,
      FlowNodeStatus.running => Colors.blue,
      FlowNodeStatus.done => Colors.green,
      FlowNodeStatus.halted => Colors.orange,
      FlowNodeStatus.failed => Colors.red,
      FlowNodeStatus.skipped => Colors.blueGrey,
      FlowNodeStatus.cancelled => Colors.grey,
      FlowNodeStatus.waitingUser => Colors.orange,
    };

class FlowNodeCard extends StatelessWidget {
  const FlowNodeCard({
    super.key,
    required this.node,
    this.onTapNode,
    this.onOpenSession,
    this.onAnswerGate,
    this.badgeFor,
    this.onLongPressNode,
    this.selected = false,
    this.selectedIds = const {},
    this.selectionMode = false,
  });

  final FlowNode node;
  final void Function(FlowNode node)? onTapNode;
  final void Function(FlowNode node)? onOpenSession;
  final void Function(FlowNode node, String choice)? onAnswerGate;
  final (String, Color)? Function(FlowNode node)? badgeFor;
  final void Function(FlowNode node)? onLongPressNode;
  final bool selected;
  final Set<String> selectedIds;
  final bool selectionMode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = node.status;
    final accent = selected
        ? theme.colorScheme.primary
        : status == null
            ? theme.dividerColor
            : flowStatusColor(status);
    final container = node.isContainer;
    final dashed = node.kind == 'plan';
    return Material(
      color: selected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
          : container
              ? theme.colorScheme.surfaceContainerLowest
              : theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: accent.withValues(alpha: dashed ? 0.5 : 0.8),
          width: selected || status == FlowNodeStatus.running ? 1.6 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTapNode == null ? null : () => onTapNode!(node),
        onLongPress:
            onLongPressNode == null ? null : () => onLongPressNode!(node),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (selectionMode)
                    Checkbox(
                      key: ValueKey('step-check-${node.id}'),
                      value: selected,
                      onChanged: onTapNode == null
                          ? null
                          : (_) => onTapNode!(node),
                    ),
                  Expanded(
                    child: Text(
                      flowKindTitle(AppLocalizations.of(context), node),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  if (badgeFor?.call(node) case (final text, final color))
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(text,
                            style: TextStyle(fontSize: 11, color: color)),
                      ),
                    ),
                  if (status != null) _StatusChip(status: status),
                  if (node.hasSession)
                    _SessionEntry(
                      node: node,
                      onOpenSession: onOpenSession,
                    ),
                ],
              ),
              if (node.desc != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(node.desc!, style: theme.textTheme.bodySmall),
                ),
              if (node.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    node.error!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                )
              else if (!container && node.text != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    node.text!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (node.awaitsAnswer && node.options.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final option in node.options)
                        FilledButton.tonal(
                          onPressed: onAnswerGate == null
                              ? null
                              : () => onAnswerGate!(node, option),
                          child: Text(option),
                        ),
                    ],
                  ),
                ),
              // P6：节点在等用户回答（ask_user / 权限确认卡片落在这条会话里）。
              // 「去回答」打开节点会话，FlowRunScreen 会带上待答卡片的高亮 id。
              // 关卡仍用上面的选项按钮，不重复。
              if (node.status?.isWaitingForUser == true && node.hasSession)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FilledButton.icon(
                      key: ValueKey('flow-node-goto-answer-${node.key}'),
                      icon: const Icon(Icons.question_answer_outlined, size: 16),
                      label: Text(AppLocalizations.of(context).flow_gotoAnswer),
                      onPressed: onOpenSession == null
                          ? null
                          : () => onOpenSession!(node),
                    ),
                  ),
                ),
              if (container)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: node.kind == 'par'
                      ? _ParallelChildren(
                          nodes: node.children,
                          onTapNode: onTapNode,
                          selectionMode: selectionMode,
                          onOpenSession: onOpenSession,
                          onAnswerGate: onAnswerGate,
                          badgeFor: badgeFor,
                          onLongPressNode: onLongPressNode,
                          selectedIds: selectedIds,
                        )
                      : FlowNodeTree(
                          nodes: node.children,
                          onTapNode: onTapNode,
                          selectionMode: selectionMode,
                          onOpenSession: onOpenSession,
                          onAnswerGate: onAnswerGate,
                          badgeFor: badgeFor,
                          onLongPressNode: onLongPressNode,
                          selectedIds: selectedIds,
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 并行分支：宽屏横排，窄屏竖排（C.6 的折叠交给分支各自的卡片）。
class _ParallelChildren extends StatelessWidget {
  const _ParallelChildren({
    required this.nodes,
    this.onTapNode,
    this.selectionMode = false,
    this.onOpenSession,
    this.onAnswerGate,
    this.badgeFor,
    this.onLongPressNode,
    this.selectedIds = const {},
  });

  final List<FlowNode> nodes;
  final void Function(FlowNode node)? onTapNode;
  final bool selectionMode;
  final void Function(FlowNode node)? onOpenSession;
  final void Function(FlowNode node, String choice)? onAnswerGate;
  final (String, Color)? Function(FlowNode node)? badgeFor;
  final void Function(FlowNode node)? onLongPressNode;
  final Set<String> selectedIds;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cards = [
          for (final node in nodes)
            FlowNodeCard(
              node: node,
              onTapNode: onTapNode,
              selectionMode: selectionMode,
              onOpenSession: onOpenSession,
              onAnswerGate: onAnswerGate,
              badgeFor: badgeFor,
              onLongPressNode: onLongPressNode,
              selected: selectedIds.contains(node.id),
            ),
        ];
        if (constraints.maxWidth < 560) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                cards[i],
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: cards[i]),
            ],
          ],
        );
      },
    );
  }
}

/// 有真会话 id 的节点才有这个入口：agent 头像 + 会话按钮。运行中在头像角上
/// 转一个小圈（主机正在往会话里推 chunk），等人回答时叠一个红点。
class _SessionEntry extends StatelessWidget {
  const _SessionEntry({required this.node, this.onOpenSession});

  final FlowNode node;
  final void Function(FlowNode node)? onOpenSession;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = node.status == FlowNodeStatus.running;
    // 等人的卡片：关卡开着、或节点处于 waitingUser（P6 的 ask_user 卡片就
    // 落在这条会话里）。halted 是终态失败、没有卡片，不画红点（A7-6）。
    final waiting = (node.kind == 'gate' && node.awaitsAnswer) ||
        (node.status?.isWaitingForUser ?? false);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              CircleAvatar(
                radius: 11,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(
                  Icons.smart_toy_outlined,
                  size: 13,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              if (waiting)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    key: const ValueKey('flow-node-session-waiting'),
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              if (running)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    width: 10,
                    height: 10,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      shape: BoxShape.circle,
                    ),
                    child: SizedBox(
                      key: const ValueKey('flow-node-session-streaming'),
                      width: 8,
                      height: 8,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            key: ValueKey('flow-node-session-${node.key}'),
            tooltip: AppLocalizations.of(context).flow_viewSession,
            icon: const Icon(Icons.chat_bubble_outline, size: 18),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            onPressed:
                onOpenSession == null ? null : () => onOpenSession!(node),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final FlowNodeStatus status;

  @override
  Widget build(BuildContext context) {
    final color = flowStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == FlowNodeStatus.running)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
            ),
          Text(
            flowStatusLabel(AppLocalizations.of(context), status),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
