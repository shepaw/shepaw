import 'package:flutter/material.dart';

/// Wraps [child] with a higher vertical scroll drag threshold so horizontal
/// drawer edge swipes are less likely to be interpreted as list scrolling.
///
/// Pair with [Scaffold.drawerEnableOpenDragGesture] /
/// [Scaffold.endDrawerEnableOpenDragGesture] and a wide
/// [Scaffold.drawerEdgeDragWidth] so the platform drawer follows the finger
/// and can be cancelled by swiping back.
class DrawerSwipeDetector extends StatelessWidget {
  const DrawerSwipeDetector({
    super.key,
    required this.child,
    this.enabled = true,
    this.verticalScrollSlop = 36,
  });

  final Widget child;
  final bool enabled;

  /// Vertical travel required before descendant scroll views start dragging.
  final double verticalScrollSlop;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;

    return ScrollConfiguration(
      behavior: _DrawerFriendlyScrollBehavior(
        verticalSlop: verticalScrollSlop,
      ),
      child: child,
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
