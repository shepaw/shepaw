import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// 设计页右侧的属性栏。
///
/// 只有当前组件（或流程设置）的属性。诊断在组件列表顶部，演练和源码走顶部按钮，
/// 这里不再分页签。宽度和收起由外层管。
class FlowContextPanel extends StatelessWidget {
  const FlowContextPanel({
    super.key,
    required this.onClose,
    required this.child,
    this.onDragWidth,
  });

  final VoidCallback onClose;
  final Widget child;

  /// 左边缘拖动时回调水平位移（向左为加宽）。
  final ValueChanged<double>? onDragWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
                  padding: const EdgeInsets.fromLTRB(16, 4, 0, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.flow_panelProperties,
                          style: theme.textTheme.titleSmall,
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
                  child: ListView(
                    key: const ValueKey('drawer-properties-page'),
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    children: [child],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
