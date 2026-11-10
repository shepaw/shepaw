import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_models.dart';
import 'flow_node_tree.dart';

/// 点开循环后，在详情里按轮次折叠每一轮的产出。
///
/// 树上只挂最后一轮，避免大纲被历史撑开。之前每一轮的结果在这里。
class FlowLoopRounds extends StatelessWidget {
  const FlowLoopRounds({
    super.key,
    required this.node,
    this.onOpenSession,
  });

  final FlowNode node;
  final void Function(FlowNode node)? onOpenSession;

  @override
  Widget build(BuildContext context) {
    final rounds = node.iterations;
    if (rounds.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final latest = rounds.last.iter;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.flow_loopRounds,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        for (final round in rounds)
          _RoundFold(
            roundKey: ValueKey('loop-round-${node.key}-${round.iter}'),
            initiallyExpanded: round.iter == latest,
            title: Row(
              children: [
                Expanded(child: Text(l10n.flow_loopRound(round.iter + 1))),
                if (round.status != null)
                  Text(
                    flowStatusLabel(l10n, round.status!),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: flowStatusColor(round.status!),
                    ),
                  ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final child in round.children)
                  _RoundStep(
                    node: child,
                    onOpenSession: onOpenSession,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 一轮的开关。收起时不构建里面的结果，点标题才展开。
class _RoundFold extends StatefulWidget {
  const _RoundFold({
    required this.roundKey,
    required this.initiallyExpanded,
    required this.title,
    required this.child,
  });

  final Key roundKey;
  final bool initiallyExpanded;
  final Widget title;
  final Widget child;

  @override
  State<_RoundFold> createState() => _RoundFoldState();
}

class _RoundFoldState extends State<_RoundFold> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: widget.roundKey,
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  _open ? Icons.expand_more : Icons.chevron_right,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Expanded(child: widget.title),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(left: 24, bottom: 8),
            child: widget.child,
          ),
      ],
    );
  }
}

class _RoundStep extends StatelessWidget {
  const _RoundStep({
    required this.node,
    this.onOpenSession,
    this.depth = 0,
  });

  final FlowNode node;
  final void Function(FlowNode node)? onOpenSession;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final status = node.status;
    return Padding(
      padding: EdgeInsets.only(left: depth * 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  flowKindTitle(l10n, node),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (status != null)
                Text(
                  flowStatusLabel(l10n, status),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: flowStatusColor(status)),
                ),
            ],
          ),
          if (node.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SelectableText(
                node.error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            )
          else if (node.text != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SelectableText(
                node.text!,
                key: ValueKey('loop-round-text-${node.key}'),
              ),
            ),
          if (node.hasSession)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: ValueKey('loop-round-session-${node.key}'),
                onPressed:
                    onOpenSession == null ? null : () => onOpenSession!(node),
                icon: const Icon(Icons.forum_outlined, size: 16),
                label: Text(l10n.flow_viewSession),
              ),
            ),
          if (node.iterations.isNotEmpty)
            FlowLoopRounds(node: node, onOpenSession: onOpenSession)
          else
            for (final child in node.children)
              _RoundStep(
                node: child,
                depth: depth + 1,
                onOpenSession: onOpenSession,
              ),
        ],
      ),
    );
  }
}
