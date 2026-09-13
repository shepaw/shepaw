import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Pins [header] to the top of this widget's visible area while scrolling.
///
/// Sticky offset is applied during **paint** after the scroll layout, so the
/// author chrome stays locked to the viewport top in the same frame. Header
/// and body live on their own layers so scrolling only moves compositor
/// offsets — it does not re-rasterize the title or the long bubble body.
///
/// While stuck, [child] is clipped below the header with [bubbleTopRadius] so
/// the visible content keeps a rounded top — it reads as bubble content
/// scrolling under a fixed author bar, not a sticker sliding over text.
class StickyInViewHeader extends StatefulWidget {
  final Widget header;
  final Widget child;
  final bool enabled;
  final bool showHeaderInFlow;
  final Color? stuckBackground;
  final List<Listenable> scrollListenables;
  final GlobalKey? viewportKey;

  /// Rounded top applied to the clipped bubble content while stuck.
  final double bubbleTopRadius;

  const StickyInViewHeader({
    super.key,
    required this.header,
    required this.child,
    this.enabled = true,
    this.showHeaderInFlow = true,
    this.stuckBackground,
    this.scrollListenables = const [],
    this.viewportKey,
    this.bubbleTopRadius = 16,
  });

  @override
  State<StickyInViewHeader> createState() => _StickyInViewHeaderState();
}

class _StickyInViewHeaderState extends State<StickyInViewHeader> {
  ScrollPosition? _position;

  @override
  void initState() {
    super.initState();
    for (final l in widget.scrollListenables) {
      l.addListener(_onScrollSignal);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attachPosition();
  }

  @override
  void didUpdateWidget(covariant StickyInViewHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.scrollListenables, widget.scrollListenables)) {
      for (final l in oldWidget.scrollListenables) {
        l.removeListener(_onScrollSignal);
      }
      for (final l in widget.scrollListenables) {
        l.addListener(_onScrollSignal);
      }
    }
  }

  @override
  void dispose() {
    _position?.removeListener(_onScrollSignal);
    for (final l in widget.scrollListenables) {
      l.removeListener(_onScrollSignal);
    }
    super.dispose();
  }

  void _attachPosition() {
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _position)) {
      _position?.removeListener(_onScrollSignal);
      _position = position;
      _position?.addListener(_onScrollSignal);
    }
  }

  void _onScrollSignal() {
    final ro = context.findRenderObject();
    if (ro is! RenderStickyInViewHeader || !ro.hasSize) return;
    // ScrollPosition 在 setPixels 时通知，此时 localToGlobal 仍是上一帧
    // 的位置。这里不能拿旧坐标做阈值比较，否则会跳过本帧 markNeedsPaint，
    // 标题跟着列表滑走一帧再弹回，看起来像模糊闪动。
    // 只标记 paint；真正偏移在 layout 之后的 paint() 里算。header/body
    // 各有独立图层，不会把长消息正文重新栅格化。
    ro.markNeedsPaint();
  }

  @override
  Widget build(BuildContext context) {
    _attachPosition();

    if (!widget.enabled) {
      if (!widget.showHeaderInFlow) return widget.child;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          widget.header,
          widget.child,
        ],
      );
    }

    final stuckBg = widget.stuckBackground ??
        Theme.of(context).scaffoldBackgroundColor;

    return _StickyInViewHeaderRender(
      showHeaderInFlow: widget.showHeaderInFlow,
      stuckBackground: stuckBg,
      bubbleTopRadius: widget.bubbleTopRadius,
      viewportKey: widget.viewportKey,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      header: widget.header,
      body: widget.child,
    );
  }
}

class _StickyInViewHeaderRender extends MultiChildRenderObjectWidget {
  final bool showHeaderInFlow;
  final Color stuckBackground;
  final double bubbleTopRadius;
  final GlobalKey? viewportKey;
  final double devicePixelRatio;

  _StickyInViewHeaderRender({
    required this.showHeaderInFlow,
    required this.stuckBackground,
    required this.bubbleTopRadius,
    required this.viewportKey,
    required this.devicePixelRatio,
    required Widget header,
    required Widget body,
  }) : super(children: [
          // 独立图层：滚动时只改 clip / offset，不重绘长正文和标题文字。
          RepaintBoundary(child: body),
          RepaintBoundary(child: header),
        ]);

  @override
  RenderStickyInViewHeader createRenderObject(BuildContext context) {
    return RenderStickyInViewHeader(
      showHeaderInFlow: showHeaderInFlow,
      stuckBackground: stuckBackground,
      bubbleTopRadius: bubbleTopRadius,
      viewportKey: viewportKey,
      devicePixelRatio: devicePixelRatio,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderStickyInViewHeader renderObject,
  ) {
    renderObject
      ..showHeaderInFlow = showHeaderInFlow
      ..stuckBackground = stuckBackground
      ..bubbleTopRadius = bubbleTopRadius
      ..viewportKey = viewportKey
      ..devicePixelRatio = devicePixelRatio;
  }
}

class _StickyParentData extends ContainerBoxParentData<RenderBox> {}

class RenderStickyInViewHeader extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _StickyParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _StickyParentData> {
  RenderStickyInViewHeader({
    required bool showHeaderInFlow,
    required Color stuckBackground,
    required double bubbleTopRadius,
    required GlobalKey? viewportKey,
    required double devicePixelRatio,
  })  : _showHeaderInFlow = showHeaderInFlow,
        _stuckBackground = stuckBackground,
        _bubbleTopRadius = bubbleTopRadius,
        _viewportKey = viewportKey,
        _devicePixelRatio = devicePixelRatio;

  bool _showHeaderInFlow;
  Color _stuckBackground;
  double _bubbleTopRadius;
  GlobalKey? _viewportKey;
  double _devicePixelRatio;

  set showHeaderInFlow(bool value) {
    if (_showHeaderInFlow == value) return;
    _showHeaderInFlow = value;
    markNeedsLayout();
  }

  set stuckBackground(Color value) {
    if (_stuckBackground == value) return;
    _stuckBackground = value;
    markNeedsPaint();
  }

  set bubbleTopRadius(double value) {
    if (_bubbleTopRadius == value) return;
    _bubbleTopRadius = value;
    markNeedsPaint();
  }

  set viewportKey(GlobalKey? value) {
    if (_viewportKey == value) return;
    _viewportKey = value;
    markNeedsPaint();
  }

  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  RenderBox? get _body => firstChild;
  RenderBox? get _header {
    final body = firstChild;
    if (body == null) return null;
    return childAfter(body);
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _StickyParentData) {
      child.parentData = _StickyParentData();
    }
  }

  @override
  void performLayout() {
    final body = _body;
    final header = _header;
    if (body == null || header == null) {
      size = constraints.smallest;
      return;
    }

    final maxWidth =
        constraints.hasBoundedWidth ? constraints.maxWidth : constraints.minWidth;

    header.layout(
      BoxConstraints(maxWidth: maxWidth),
      parentUsesSize: true,
    );

    final reservedHeaderH = _showHeaderInFlow ? header.size.height : 0.0;

    // Loose width so the bubble can shrink-wrap content; author chrome may
    // still span the full row via Expanded in the header.
    body.layout(
      BoxConstraints(maxWidth: maxWidth),
      parentUsesSize: true,
    );

    final contentWidth = math.max(header.size.width, body.size.width);
    size = constraints.constrain(
      Size(contentWidth, reservedHeaderH + body.size.height),
    );

    final bodyParentData = body.parentData! as _StickyParentData;
    bodyParentData.offset = Offset(0, reservedHeaderH);

    final headerParentData = header.parentData! as _StickyParentData;
    headerParentData.offset = Offset.zero;
  }

  double _snapToPhysicalPixel(double logical) {
    final dpr = _devicePixelRatio;
    if (dpr <= 0) return logical.roundToDouble();
    return (logical * dpr).round() / dpr;
  }

  double _stuckOffset(RenderBox header) {
    final viewportTop = _viewportTopGlobal();
    if (viewportTop == null || !hasSize) return 0;

    final itemTop = localToGlobal(Offset.zero).dy - viewportTop;
    if (itemTop >= 0) return 0;

    final headerH = header.size.height;
    final maxOffset = math.max(0.0, size.height - headerH);
    final raw = (-itemTop).clamp(0.0, maxOffset);
    // 按屏幕坐标对齐物理像素，避免标题每帧在亚像素位置重绘发糊。
    final snappedGlobal = _snapToPhysicalPixel(viewportTop + itemTop + raw);
    return (snappedGlobal - viewportTop - itemTop).clamp(0.0, maxOffset);
  }

  double? _viewportTopGlobal() {
    final viewportKeyBox =
        _viewportKey?.currentContext?.findRenderObject() as RenderBox?;
    if (viewportKeyBox != null && viewportKeyBox.hasSize) {
      return viewportKeyBox.localToGlobal(Offset.zero).dy;
    }

    final viewport = RenderAbstractViewport.maybeOf(this);
    final viewportBox = viewport is RenderBox ? viewport as RenderBox : null;
    if (viewportBox != null && viewportBox.hasSize) {
      return viewportBox.localToGlobal(Offset.zero).dy;
    }
    return null;
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final body = _body;
    final header = _header;
    if (body == null || header == null) return;

    final stuck = _stuckOffset(header);
    final headerH = header.size.height;
    final bodyParentData = body.parentData! as _StickyParentData;
    final bodyLayoutOffset = _showHeaderInFlow
        ? bodyParentData.offset
        : Offset.zero;
    final bodyOffset = offset + bodyLayoutOffset;

    if (stuck > 0.5) {
      final clipTop = offset.dy + stuck + headerH;
      final clipRect = Rect.fromLTRB(
        offset.dx,
        clipTop,
        offset.dx + size.width,
        offset.dy + size.height,
      );
      if (clipRect.height > 0 && clipRect.width > 0) {
        final radius = Radius.circular(_bubbleTopRadius);
        final clipRRect = RRect.fromRectAndCorners(
          clipRect,
          topLeft: radius,
          topRight: radius,
        );
        context.pushClipRRect(
          needsCompositing,
          Offset.zero,
          clipRect,
          clipRRect,
          (PaintingContext ctx, Offset _) {
            ctx.paintChild(body, bodyOffset);
          },
        );
      }

      final headerTop = offset.dy + stuck;
      final headerRect =
          Rect.fromLTWH(offset.dx, headerTop, size.width, headerH);
      context.canvas.drawRect(headerRect, Paint()..color = _stuckBackground);
      context.paintChild(header, Offset(offset.dx, headerTop));
      return;
    }

    if (_showHeaderInFlow) {
      context.paintChild(header, offset);
      context.paintChild(body, bodyOffset);
    } else {
      context.paintChild(body, bodyOffset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final header = _header;
    final body = _body;
    if (header == null || body == null) return false;

    final stuck = _stuckOffset(header);
    final headerH = header.size.height;
    final bodyParentData = body.parentData! as _StickyParentData;
    final bodyLayoutOffset =
        _showHeaderInFlow ? bodyParentData.offset : Offset.zero;

    if (stuck > 0.5) {
      final headerTopLeft = Offset(0, stuck);
      if (position.dy >= stuck && position.dy < stuck + headerH) {
        return result.addWithPaintOffset(
          offset: headerTopLeft,
          position: position,
          hitTest: (BoxHitTestResult r, Offset transformed) {
            return header.hitTest(r, position: transformed);
          },
        );
      }
      return result.addWithPaintOffset(
        offset: bodyLayoutOffset,
        position: position,
        hitTest: (BoxHitTestResult r, Offset transformed) {
          return body.hitTest(r, position: transformed);
        },
      );
    }

    if (_showHeaderInFlow) {
      if (position.dy < headerH) {
        return result.addWithPaintOffset(
          offset: Offset.zero,
          position: position,
          hitTest: (BoxHitTestResult r, Offset transformed) {
            return header.hitTest(r, position: transformed);
          },
        );
      }
    }

    return result.addWithPaintOffset(
      offset: bodyLayoutOffset,
      position: position,
      hitTest: (BoxHitTestResult r, Offset transformed) {
        return body.hitTest(r, position: transformed);
      },
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (child == _header) {
      final stuck = _stuckOffset(child);
      transform.translateByDouble(0.0, stuck, 0.0, 1.0);
      return;
    }
    final parentData = child.parentData! as _StickyParentData;
    final o = _showHeaderInFlow ? parentData.offset : Offset.zero;
    transform.translateByDouble(o.dx, o.dy, 0.0, 1.0);
  }
}
