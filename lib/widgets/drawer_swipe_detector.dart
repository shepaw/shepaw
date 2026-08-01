import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Decision for a candidate drawer-open swipe while a pointer is moving.
@visibleForTesting
enum DrawerSwipeDecision {
  /// Not enough movement yet, or still ambiguous.
  wait,

  /// Movement is vertical-dominant; yield so list scrolling can win.
  rejectAsVertical,

  /// Movement is a clear rightward open gesture.
  acceptOpen,

  /// Movement is clearly horizontal but not a rightward open (e.g. left swipe).
  rejectAsHorizontal,
}

/// Pure disambiguation used by [_DrawerOpenSwipeRecognizer].
///
/// Vertical scrolling wins as soon as movement is vertical-dominant past
/// [touchSlop]. A drawer open is accepted only when the swipe is clearly
/// rightward past [minOpenDistance].
@visibleForTesting
DrawerSwipeDecision decideDrawerSwipe({
  required double dx,
  required double dy,
  double touchSlop = kTouchSlop,
  double horizontalDominance = 1.25,
  double minOpenDistance = 36,
}) {
  final absDx = dx.abs();
  final absDy = dy.abs();
  final distance = Offset(dx, dy).distance;
  if (distance < touchSlop) {
    return DrawerSwipeDecision.wait;
  }

  // Vertical priority: as soon as up/down dominates, give up.
  if (absDy >= absDx) {
    return DrawerSwipeDecision.rejectAsVertical;
  }

  // Clearly leftward — not an open gesture.
  if (dx <= 0) {
    return DrawerSwipeDecision.rejectAsHorizontal;
  }

  // Need a clear horizontal bias before claiming the arena.
  if (dx < absDy * horizontalDominance) {
    return DrawerSwipeDecision.wait;
  }

  if (dx >= minOpenDistance) {
    return DrawerSwipeDecision.acceptOpen;
  }

  return DrawerSwipeDecision.wait;
}

/// Helps the home drawer coexist with vertical conversation-list scrolling.
///
/// Disables relying on a full-screen [Scaffold.drawerEdgeDragWidth] (which
/// steals lightly-diagonal scrolls). Instead, a custom recognizer claims the
/// pointer only for clearly rightward swipes; vertical-dominant moves are
/// rejected so the list can scroll.
///
/// Pair with [Scaffold.drawerEnableOpenDragGesture] set to false, and provide
/// [onOpenDrawer] (typically `() => scaffoldKey.currentState?.openDrawer()`).
///
/// When [blockLeadingEdgeDrawerGesture] is true, pointers that begin inside
/// the system-back edge strip are ignored so iOS/Android back gestures are
/// not contested.
class DrawerSwipeDetector extends StatelessWidget {
  const DrawerSwipeDetector({
    super.key,
    required this.child,
    this.enabled = true,
    this.onOpenDrawer,
    this.verticalScrollSlop = 18,
    this.blockLeadingEdgeDrawerGesture = false,
    this.leadingEdgeBlockWidth,
    this.touchSlop = kTouchSlop,
    this.horizontalDominance = 1.25,
    this.minOpenDistance = 36,
  });

  final Widget child;
  final bool enabled;

  /// Opens the scaffold drawer when a clear rightward swipe is recognized.
  final VoidCallback? onOpenDrawer;

  /// Vertical travel required before descendant scroll views start dragging.
  /// Keep near [kTouchSlop] so list motion feels immediate after winning.
  final double verticalScrollSlop;

  /// When true, ignore open-swipes that start on the left system-gesture edge.
  final bool blockLeadingEdgeDrawerGesture;

  /// Width of the left edge strip that ignores open-swipes. When null, uses
  /// [MediaQuery.systemGestureInsets] with a small buffer.
  final double? leadingEdgeBlockWidth;

  final double touchSlop;
  final double horizontalDominance;
  final double minOpenDistance;

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
    if (!enabled) return child;

    final leadingBlock = blockLeadingEdgeDrawerGesture
        ? resolveLeadingEdgeBlockWidth(
            context,
            override: leadingEdgeBlockWidth,
          )
        : 0.0;

    Widget result = child;

    if (onOpenDrawer != null) {
      result = RawGestureDetector(
        gestures: <Type, GestureRecognizerFactory>{
          _DrawerOpenSwipeRecognizer:
              GestureRecognizerFactoryWithHandlers<_DrawerOpenSwipeRecognizer>(
            () => _DrawerOpenSwipeRecognizer(
              touchSlop: touchSlop,
              horizontalDominance: horizontalDominance,
              minOpenDistance: minOpenDistance,
              blockedLeadingWidth: leadingBlock,
            ),
            (_DrawerOpenSwipeRecognizer instance) {
              instance.onOpen = onOpenDrawer;
            },
          ),
        },
        child: result,
      );
    }

    return ScrollConfiguration(
      behavior: _DrawerFriendlyScrollBehavior(
        verticalSlop: verticalScrollSlop,
      ),
      child: result,
    );
  }
}

class _DrawerOpenSwipeRecognizer extends OneSequenceGestureRecognizer {
  _DrawerOpenSwipeRecognizer({
    required this.touchSlop,
    required this.horizontalDominance,
    required this.minOpenDistance,
    required this.blockedLeadingWidth,
  });

  final double touchSlop;
  final double horizontalDominance;
  final double minOpenDistance;
  final double blockedLeadingWidth;

  VoidCallback? onOpen;

  Offset _offset = Offset.zero;
  bool _resolved = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (blockedLeadingWidth > 0 && event.position.dx <= blockedLeadingWidth) {
      return;
    }
    _offset = Offset.zero;
    _resolved = false;
    startTrackingPointer(event.pointer, event.transform);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      if (_resolved) return;
      _offset += event.delta;
      switch (decideDrawerSwipe(
        dx: _offset.dx,
        dy: _offset.dy,
        touchSlop: touchSlop,
        horizontalDominance: horizontalDominance,
        minOpenDistance: minOpenDistance,
      )) {
        case DrawerSwipeDecision.wait:
          break;
        case DrawerSwipeDecision.rejectAsVertical:
        case DrawerSwipeDecision.rejectAsHorizontal:
          _resolved = true;
          resolve(GestureDisposition.rejected);
        case DrawerSwipeDecision.acceptOpen:
          _resolved = true;
          resolve(GestureDisposition.accepted);
          onOpen?.call();
      }
      return;
    }

    if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (!_resolved) {
        _resolved = true;
        resolve(GestureDisposition.rejected);
      }
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {
    _resolved = true;
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    if (!_resolved) {
      resolve(GestureDisposition.rejected);
    }
  }

  @override
  String get debugDescription => 'drawer open swipe';
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
