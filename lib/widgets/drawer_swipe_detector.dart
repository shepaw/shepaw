import 'package:flutter/material.dart';

/// Wraps [child] with a higher vertical scroll drag threshold so horizontal
/// drawer edge swipes are less likely to be interpreted as list scrolling.
///
/// Pair with [Scaffold.drawerEnableOpenDragGesture] /
/// [Scaffold.endDrawerEnableOpenDragGesture] and a wide
/// [Scaffold.drawerEdgeDragWidth] so the platform drawer follows the finger
/// and can be cancelled by swiping back.
///
/// When [blockLeadingEdgeDrawerGesture] is true, a narrow strip on the left
/// screen edge absorbs pointer events so the scaffold drawer drag does not
/// compete with the system back gesture.
class DrawerSwipeDetector extends StatelessWidget {
  const DrawerSwipeDetector({
    super.key,
    required this.child,
    this.enabled = true,
    this.verticalScrollSlop = 36,
    this.blockLeadingEdgeDrawerGesture = false,
    this.leadingEdgeBlockWidth,
  });

  final Widget child;
  final bool enabled;

  /// Vertical travel required before descendant scroll views start dragging.
  final double verticalScrollSlop;

  /// When true, block drawer drag gestures that start on the left edge.
  final bool blockLeadingEdgeDrawerGesture;

  /// Width of the left edge strip that blocks drawer drag. When null, uses
  /// [MediaQuery.systemGestureInsets] with a small buffer.
  final double? leadingEdgeBlockWidth;

  static double resolveLeadingEdgeBlockWidth(
    BuildContext context, {
    double? override,
  }) {
    if (override != null) return override;
    final systemInset = MediaQuery.systemGestureInsetsOf(context).left;
    if (systemInset > 0) return systemInset + 4;
    return 20;
  }

  @override
  Widget build(BuildContext context) {
    Widget result = child;

    if (enabled && blockLeadingEdgeDrawerGesture) {
      final blockWidth = resolveLeadingEdgeBlockWidth(
        context,
        override: leadingEdgeBlockWidth,
      );
      result = Stack(
        clipBehavior: Clip.none,
        children: [
          result,
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: blockWidth,
            child: const AbsorbPointer(),
          ),
        ],
      );
    }

    if (!enabled) return result;

    return ScrollConfiguration(
      behavior: _DrawerFriendlyScrollBehavior(
        verticalSlop: verticalScrollSlop,
      ),
      child: result,
    );
  }
}

class _DrawerFriendlyScrollBehavior extends MaterialScrollBehavior {
  const _DrawerFriendlyScrollBehavior({
    required this.verticalSlop,
  });

  final double verticalSlop;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return _SlopScrollPhysics(
      verticalSlop: verticalSlop,
      parent: super.getScrollPhysics(context),
    );
  }

  @override
  bool shouldNotify(covariant _DrawerFriendlyScrollBehavior oldDelegate) {
    return oldDelegate.verticalSlop != verticalSlop;
  }
}

class _SlopScrollPhysics extends ScrollPhysics {
  const _SlopScrollPhysics({
    required this.verticalSlop,
    super.parent,
  });

  final double verticalSlop;

  @override
  _SlopScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _SlopScrollPhysics(
      verticalSlop: verticalSlop,
      parent: buildParent(ancestor),
    );
  }

  @override
  double? get dragStartDistanceMotionThreshold => verticalSlop;
}
