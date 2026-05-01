/// Slash-command palette — the "/" equivalent of the `@mention` picker.
///
/// Rendered conditionally in [ChatInputArea]'s build() Column above the
/// input field, mirroring the mention picker's visual and interaction
/// style: ListView of selectable rows, keyboard ↑/↓/Enter support driven
/// by the parent's focus node, tap-to-insert.
///
/// Data comes from [ACPAgentConnection.slashCommands] (seeded via
/// `agent.commands.list` on connect, refreshed on `agent.commands.changed`
/// notifications). The filtering is done locally on the `name` and
/// `description` fields against the user's typed query after `/`.
library;

import 'package:flutter/material.dart';

import '../../models/acp_protocol.dart';

class SlashCommandPicker extends StatelessWidget {
  final List<SlashCommandInfo> commands;
  final String query;
  final int selectedIndex;
  final ValueChanged<SlashCommandInfo> onSelect;
  final ValueChanged<int> onHover;
  final ScrollController? scrollController;

  const SlashCommandPicker({
    super.key,
    required this.commands,
    required this.query,
    required this.selectedIndex,
    required this.onSelect,
    required this.onHover,
    this.scrollController,
  });

  /// Filter by prefix-then-contains on name, contains on description.
  /// Returns at most 20 entries so the list stays pageable.
  static List<SlashCommandInfo> filter(
    List<SlashCommandInfo> commands,
    String query,
  ) {
    final q = query.toLowerCase();
    if (q.isEmpty) return commands.take(20).toList(growable: false);
    final starts = <SlashCommandInfo>[];
    final contains = <SlashCommandInfo>[];
    for (final c in commands) {
      final name = c.name.toLowerCase();
      if (name.startsWith(q)) {
        starts.add(c);
      } else if (name.contains(q) ||
          (c.description?.toLowerCase().contains(q) ?? false)) {
        contains.add(c);
      }
    }
    return [...starts, ...contains].take(20).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = filter(commands, query);
    if (filtered.isEmpty) return const SizedBox.shrink();

    const itemHeight = 52.0;
    final maxHeight = (filtered.length * itemHeight).clamp(0.0, 220.0);

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      margin: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: ListView.builder(
        controller: scrollController,
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: filtered.length,
        itemBuilder: (context, index) {
          final cmd = filtered[index];
          final isSelected = index == selectedIndex;
          return MouseRegion(
            onEnter: (_) => onHover(index),
            child: Material(
              color: isSelected
                  ? Theme.of(context).primaryColor.withOpacity(0.08)
                  : Colors.transparent,
              child: InkWell(
                onTap: () => onSelect(cmd),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Text(
                        '/${cmd.name}',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).primaryColor,
                          fontFamily: 'monospace',
                        ),
                      ),
                      if (cmd.argumentHint != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          cmd.argumentHint!,
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                      const SizedBox(width: 10),
                      if (cmd.description != null)
                        Expanded(
                          child: Text(
                            cmd.description!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.grey[700],
                              fontSize: 13,
                            ),
                          ),
                        )
                      else
                        const Spacer(),
                      if (cmd.scope != null)
                        _ScopeBadge(scope: cmd.scope!),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ScopeBadge extends StatelessWidget {
  final CommandScope scope;

  const _ScopeBadge({required this.scope});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (scope) {
      CommandScope.project => ('project', Colors.blueGrey),
      CommandScope.user => ('user', Colors.teal),
      CommandScope.builtin => ('builtin', Colors.deepPurple),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
