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
    this.onAnswerGate,
  });

  final List<FlowNode> nodes;
  final void Function(FlowNode node)? onTapNode;

  /// 关卡卡片上点了某个选项。
  final void Function(FlowNode node, String choice)? onAnswerGate;

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
            onAnswerGate: onAnswerGate,
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
    };

Color flowStatusColor(FlowNodeStatus status) => switch (status) {
      FlowNodeStatus.pending => Colors.grey,
      FlowNodeStatus.running => Colors.blue,
      FlowNodeStatus.done => Colors.green,
      FlowNodeStatus.halted => Colors.orange,
      FlowNodeStatus.failed => Colors.red,
      FlowNodeStatus.skipped => Colors.blueGrey,
      FlowNodeStatus.cancelled => Colors.grey,
    };

class FlowNodeCard extends StatelessWidget {
  const FlowNodeCard({
    super.key,
    required this.node,
    this.onTapNode,
    this.onAnswerGate,
  });

  final FlowNode node;
  final void Function(FlowNode node)? onTapNode;
  final void Function(FlowNode node, String choice)? onAnswerGate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = node.status;
    final accent = status == null ? theme.dividerColor : flowStatusColor(status);
    final container = node.isContainer;
    final dashed = node.kind == 'plan';
    return Material(
      color: container
          ? theme.colorScheme.surfaceContainerLowest
          : theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: accent.withValues(alpha: dashed ? 0.5 : 0.8),
          width: status == FlowNodeStatus.running ? 1.6 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTapNode == null ? null : () => onTapNode!(node),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      flowKindTitle(AppLocalizations.of(context), node),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  if (status != null) _StatusChip(status: status),
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
              if (container)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: node.kind == 'par'
                      ? _ParallelChildren(
                          nodes: node.children,
                          onTapNode: onTapNode,
                          onAnswerGate: onAnswerGate,
                        )
                      : FlowNodeTree(
                          nodes: node.children,
                          onTapNode: onTapNode,
                          onAnswerGate: onAnswerGate,
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
    this.onAnswerGate,
  });

  final List<FlowNode> nodes;
  final void Function(FlowNode node)? onTapNode;
  final void Function(FlowNode node, String choice)? onAnswerGate;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cards = [
          for (final node in nodes)
            FlowNodeCard(
              node: node,
              onTapNode: onTapNode,
              onAnswerGate: onAnswerGate,
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
