import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// 设计页右侧的上下文面板：属性 / 问题 / 演练 / 源码。
///
/// 「对比」不占页签。宽度和收起由外层管，这里只画页签和当前页。
class FlowContextPanel extends StatelessWidget {
  const FlowContextPanel({
    super.key,
    required this.tab,
    required this.onTab,
    required this.onClose,
    required this.problemCount,
    required this.properties,
    required this.problems,
    required this.rehearsal,
    required this.source,
    this.onDragWidth,
  });

  final String tab;
  final ValueChanged<String> onTab;
  final VoidCallback onClose;
  final int problemCount;
  final Widget properties;
  final Widget problems;
  final Widget rehearsal;
  final Widget source;

  /// 左边缘拖动时回调水平位移（向左为加宽）。
  final ValueChanged<double>? onDragWidth;

  static const tabs = ['properties', 'problems', 'rehearsal', 'source'];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final index = tabs.contains(tab) ? tabs.indexOf(tab) : 0;
    final labels = [
      l10n.flow_panelProperties,
      problemCount > 0
          ? l10n.flow_drawerProblemsCount(problemCount)
          : l10n.flow_drawerProblems,
      l10n.flow_drawerRehearsal,
      l10n.flow_drawerSource,
    ];
    final keys = [
      'drawer-tab-properties',
      'drawer-tab-problems',
      'drawer-tab-rehearsal',
      'drawer-tab-source',
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          left: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          if (onDragWidth != null)
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) =>
                    onDragWidth!(-details.delta.dx),
                child: const SizedBox(width: 6),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 0, 4),
                  child: Row(
                    children: [
                      for (var i = 0; i < tabs.length; i++)
                        Expanded(
                          child: InkWell(
                            key: ValueKey(keys[i]),
                            onTap: () => onTab(tabs[i]),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    width: index == i ? 2 : 0,
                                    color: index == i
                                        ? scheme.primary
                                        : Colors.transparent,
                                  ),
                                ),
                              ),
                              child: Text(
                                labels[i],
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: index == i
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                      IconButton(
                        key: const ValueKey('drawer-close'),
                        tooltip: l10n.flow_drawerClose,
                        icon: const Icon(Icons.keyboard_double_arrow_right,
                            size: 18),
                        onPressed: onClose,
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: scheme.outlineVariant),
                Expanded(
                  child: IndexedStack(
                    index: index,
                    children: [
                      _scroll(properties),
                      problems,
                      rehearsal,
                      source,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _scroll(Widget child) => ListView(
        key: const ValueKey('drawer-properties-page'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [child],
      );
}
