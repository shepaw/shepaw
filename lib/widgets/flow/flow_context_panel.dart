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
class FlowPaneSplitter extends StatefulWidget {
  const FlowPaneSplitter({
    super.key,
    required this.onDrag,
    this.handleKey,
  });

  /// 水平位移。向右为正，调用方据此缩小右侧属性栏。
  final ValueChanged<double> onDrag;

  /// 拖动手柄的键。同一页有多条分割线时分开，避免测试和命中叠在一起。
  final Key? handleKey;

  @override
  State<FlowPaneSplitter> createState() => _FlowPaneSplitterState();
}

class _FlowPaneSplitterState extends State<FlowPaneSplitter> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 浅色整条缝，中间再加一条稍清楚的线，方便找着拖。
    final track = scheme.outlineVariant.withValues(alpha: _hover ? 0.45 : 0.22);
    final line = scheme.outlineVariant.withValues(alpha: _hover ? 0.85 : 0.45);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: widget.handleKey ?? const ValueKey('flow-pane-splitter'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
        child: ColoredBox(
          color: track,
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
      ),
    );
  }
}
