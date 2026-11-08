import 'package:flutter/material.dart';

/// 设计页右侧的属性栏。
///
/// 只有当前组件（或流程设置）的属性。诊断在组件列表顶部，演练和源码走顶部按钮，
/// 这里不再分页签，也不再画一条「属性」标题。和左侧流程树之间的分割线由
/// [FlowPaneSplitter] 画，拖它改两边的宽度。
class FlowContextPanel extends StatelessWidget {
  const FlowContextPanel({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: ListView(
        key: const ValueKey('drawer-properties-page'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [child],
      ),
    );
  }
}

/// 流程树和属性栏中间的分割线。向左拖，属性栏变宽。
class FlowPaneSplitter extends StatelessWidget {
  const FlowPaneSplitter({super.key, required this.onDrag});

  /// 水平位移。向右为正，调用方据此缩小右侧属性栏。
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final line = Theme.of(context).colorScheme.outlineVariant;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        key: const ValueKey('flow-pane-splitter'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        child: SizedBox(
          width: 9,
          child: Center(
            child: ColoredBox(
              color: line,
              child: const SizedBox(width: 1),
            ),
          ),
        ),
      ),
    );
  }
}
