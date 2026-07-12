import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A wrapper widget that allows long content to be collapsed/expanded.
///
/// Useful for "thinking" messages or verbose agent output that should
/// be collapsed by default or auto-collapsed when streaming finishes.
///
/// Collapsed height follows the child's intrinsic size up to
/// [collapsedMaxHeight] — short content will not leave empty space.
class CollapsibleMessageBubble extends StatefulWidget {
  final Widget child;
  final bool initiallyCollapsed;
  final bool autoCollapseOnComplete;
  final bool isStreaming;
  final double collapsedMaxHeight;
  final String? title;
  final bool isMyMessage;

  const CollapsibleMessageBubble({
    Key? key,
    required this.child,
    this.initiallyCollapsed = false,
    this.autoCollapseOnComplete = false,
    this.isStreaming = false,
    this.collapsedMaxHeight = 80.0,
    this.title,
    this.isMyMessage = false,
  }) : super(key: key);

  @override
  State<CollapsibleMessageBubble> createState() =>
      _CollapsibleMessageBubbleState();
}

class _CollapsibleMessageBubbleState extends State<CollapsibleMessageBubble> {
  late bool _isCollapsed;
  bool _wasStreaming = false;

  @override
  void initState() {
    super.initState();
    _isCollapsed = widget.initiallyCollapsed;
    _wasStreaming = widget.isStreaming;
  }

  @override
  void didUpdateWidget(covariant CollapsibleMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Detect streaming completion: was streaming, now not streaming
    if (widget.autoCollapseOnComplete &&
        _wasStreaming &&
        !widget.isStreaming) {
      setState(() {
        _isCollapsed = true;
      });
    }
    _wasStreaming = widget.isStreaming;
  }

  void _toggle() {
    setState(() {
      _isCollapsed = !_isCollapsed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final headerColor =
        widget.isMyMessage ? Colors.white70 : Colors.black54;
    final chevronColor =
        widget.isMyMessage ? Colors.white60 : Colors.black45;
    final fadeColor = widget.isMyMessage
        ? Theme.of(context).primaryColor
        : (Colors.grey[200] ?? Colors.grey);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Header row with title and toggle
        GestureDetector(
          onTap: _toggle,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isCollapsed
                      ? Icons.chevron_right
                      : Icons.expand_more,
                  size: 18,
                  color: chevronColor,
                ),
                const SizedBox(width: 2),
                if (widget.title != null)
                  Flexible(
                    child: Text(
                      widget.title!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: headerColor,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (widget.isStreaming) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      valueColor: AlwaysStoppedAnimation<Color>(headerColor),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        _CollapsibleContent(
          collapsed: _isCollapsed,
          collapsedMaxHeight: widget.collapsedMaxHeight,
          fadeColor: fadeColor,
          child: widget.child,
        ),
      ],
    );
  }
}

/// Lays out [child] at its intrinsic height, then sizes itself to that height
/// when expanded, or `min(intrinsic, collapsedMaxHeight)` when collapsed.
/// Draws a bottom fade only when content is actually clipped.
class _CollapsibleContent extends SingleChildRenderObjectWidget {
  final bool collapsed;
  final double collapsedMaxHeight;
  final Color fadeColor;

  const _CollapsibleContent({
    required this.collapsed,
    required this.collapsedMaxHeight,
    required this.fadeColor,
    required Widget child,
  }) : super(child: child);

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderCollapsibleContent(
      collapsed: collapsed,
      collapsedMaxHeight: collapsedMaxHeight,
      fadeColor: fadeColor,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderCollapsibleContent renderObject,
  ) {
    renderObject
      ..collapsed = collapsed
      ..collapsedMaxHeight = collapsedMaxHeight
      ..fadeColor = fadeColor;
  }
}

class _RenderCollapsibleContent extends RenderProxyBox {
  _RenderCollapsibleContent({
    required bool collapsed,
    required double collapsedMaxHeight,
    required Color fadeColor,
  })  : _collapsed = collapsed,
        _collapsedMaxHeight = collapsedMaxHeight,
        _fadeColor = fadeColor;

  bool _collapsed;
  bool get collapsed => _collapsed;
  set collapsed(bool value) {
    if (_collapsed == value) return;
    _collapsed = value;
    markNeedsLayout();
  }

  double _collapsedMaxHeight;
  double get collapsedMaxHeight => _collapsedMaxHeight;
  set collapsedMaxHeight(double value) {
    if (_collapsedMaxHeight == value) return;
    _collapsedMaxHeight = value;
    markNeedsLayout();
  }

  Color _fadeColor;
  Color get fadeColor => _fadeColor;
  set fadeColor(Color value) {
    if (_fadeColor == value) return;
    _fadeColor = value;
    markNeedsPaint();
  }

  bool _overflows = false;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      _overflows = false;
      return;
    }

    // Layout child with unbounded max height so we learn its intrinsic size.
    child.layout(
      BoxConstraints(
        minWidth: constraints.minWidth,
        maxWidth: constraints.maxWidth,
        minHeight: 0,
        maxHeight: double.infinity,
      ),
      parentUsesSize: true,
    );

    final childHeight = child.size.height;
    _overflows = _collapsed && childHeight > _collapsedMaxHeight + 0.5;
    final displayHeight =
        _overflows ? _collapsedMaxHeight : childHeight;

    size = constraints.constrain(Size(child.size.width, displayHeight));
  }

  @override
  bool get alwaysNeedsCompositing => _overflows;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;

    if (_overflows) {
      context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        (PaintingContext ctx, Offset off) {
          ctx.paintChild(child, off);
          _paintFade(ctx, off);
        },
      );
    } else {
      context.paintChild(child, offset);
    }
  }

  void _paintFade(PaintingContext context, Offset offset) {
    const fadeHeight = 40.0;
    final rect = Rect.fromLTWH(
      offset.dx,
      offset.dy + size.height - fadeHeight,
      size.width,
      fadeHeight,
    );
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          _fadeColor.withValues(alpha: 0.0),
          _fadeColor,
        ],
      ).createShader(rect);
    context.canvas.drawRect(rect, paint);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (position.dy < 0 || position.dy >= size.height) return false;
    return super.hitTestChildren(result, position: position);
  }
}
