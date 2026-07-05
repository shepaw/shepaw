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
import 'package:flutter/scheduler.dart';

import '../../models/acp_protocol.dart';

class SlashCommandPicker extends StatefulWidget {
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
  State<SlashCommandPicker> createState() => _SlashCommandPickerState();
}

class _SlashCommandPickerState extends State<SlashCommandPicker> {
  static const _itemHeight = 52.0;
  static const _maxListHeight = 220.0;

  int _previousSelectedIndex = 0;

  @override
  void didUpdateWidget(SlashCommandPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query || oldWidget.commands != widget.commands) {
      _scheduleJumpTo(0);
    }
    if (widget.selectedIndex != oldWidget.selectedIndex) {
      _previousSelectedIndex = oldWidget.selectedIndex;
      _scheduleScrollToSelected();
    }
  }

  void _scheduleJumpTo(double offset) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = widget.scrollController;
      if (controller == null || !controller.hasClients) return;
      controller.jumpTo(offset.clamp(0.0, controller.position.maxScrollExtent));
    });
  }

  void _scheduleScrollToSelected() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToSelected();
    });
  }

  /// Scroll only when the selection would leave the viewport — the
  /// highlight moves within the visible window; the list shifts by one
  /// row only at the top/bottom edge.
  void _scrollToSelected() {
    final controller = widget.scrollController;
    if (controller == null || !controller.hasClients) return;

    final filtered = SlashCommandPicker.filter(widget.commands, widget.query);
    final from = _previousSelectedIndex;
    final to = widget.selectedIndex;
    final length = filtered.length;
    if (length == 0) return;

    final position = controller.position;

    // Wrap-around jumps to the opposite end of the list.
    if (length > 1 && from == length - 1 && to == 0) {
      _animateScroll(0);
      return;
    }
    if (length > 1 && from == 0 && to == length - 1) {
      _animateScroll(position.maxScrollExtent);
      return;
    }

    final itemTop = to * _itemHeight;
    final itemBottom = itemTop + _itemHeight;
    final viewportTop = controller.offset;
    final viewportBottom = viewportTop + position.viewportDimension;

    double? target;
    if (to > from) {
      if (itemBottom > viewportBottom) {
        target = itemBottom - position.viewportDimension;
      }
    } else if (to < from) {
      if (itemTop < viewportTop) {
        target = itemTop;
      }
    }

    if (target != null) {
      _animateScroll(target);
    }
  }

  void _animateScroll(double offset) {
    final controller = widget.scrollController;
    if (controller == null || !controller.hasClients) return;
    controller.animateTo(
      offset.clamp(0.0, controller.position.maxScrollExtent),
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = SlashCommandPicker.filter(widget.commands, widget.query);
    if (filtered.isEmpty) return const SizedBox.shrink();

    final listHeight =
        (filtered.length * _itemHeight).clamp(0.0, _maxListHeight);

    return Container(
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
      child: SizedBox(
        height: listHeight,
        child: ListView.builder(
          controller: widget.scrollController,
          padding: EdgeInsets.zero,
          itemExtent: _itemHeight,
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final cmd = filtered[index];
            final isSelected = index == widget.selectedIndex;
            return MouseRegion(
              onEnter: (_) => widget.onHover(index),
              child: Material(
                color: isSelected
                    ? Theme.of(context).primaryColor.withOpacity(0.08)
                    : Colors.transparent,
                child: InkWell(
                  onTap: () => widget.onSelect(cmd),
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
                        if (cmd.scope != null) _ScopeBadge(scope: cmd.scope!),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
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
