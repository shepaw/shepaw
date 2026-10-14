import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// Coordinates scroll anchoring during streaming output in a reverse-ordered
/// chat message list (`ScrollablePositionedList(reverse: true)`).
///
/// Why this exists:
/// 1. In a `reverse: true` viewport anchored at `index 0` (the newest message),
///    scroll offset `0.0` is at the visual bottom. When the user is at the
///    bottom (`!isUserScrolledUp`), `index 0` growing in height naturally stays
///    pinned at `0.0` without needing programmatic `jumpTo(index: 0)` calls on
///    every chunk (which would call `ScrollPosition.goIdle()` and cancel active
///    user drags/flings).
/// 2. When the user scrolls up (`isUserScrolledUp == true`), `index 0` lies
///    between `0.0` and the user's current `pixels` offset. Any height increase
///    `+ΔH` of a streaming bubble in `GrowthDirection.forward` shifts all
///    content above the bottom of `index 0` (both older history messages and
///    the upper portion of `index 0` itself) by `+ΔH`.
/// 3. By recording `+ΔH` during [RenderStreamingSizeTracker.performLayout] and
///    applying it in [ChatStreamScrollPhysics.adjustPositionForNewDimensions]
///    within the same [RenderViewport.performLayout] pass, `pixels` is
///    compensated by `+ΔH` before painting — keeping the user's reading
///    viewport completely stationary without interrupting active drags,
///    momentum flings, or scrollbar interactions.
class StreamingScrollAnchor {
  /// Leading-edge threshold (fraction of viewport height) for considering
  /// `index 0`'s bottom edge to be at the visual bottom of the viewport.
  ///
  /// With `padding: EdgeInsets.all(16)` on `ScrollablePositionedList`, at
  /// `pixels == 0`, `index 0` has `itemLeadingEdge == 16 / viewportHeight > 0`.
  /// Once the user scrolls up past the 16px bottom padding, `itemLeadingEdge`
  /// becomes `< 0.0`.
  static const double bottomLeadingEdgeThreshold = 0.0;

  /// Pixel tolerance from `minScrollExtent` (`0.0`) for considering the scroll
  /// position to be settled at the bottom.
  static const double bottomPixelTolerance = 8.0;

  bool isUserScrolledUp = false;
  double _pendingForwardExtentDelta = 0.0;

  /// Latest scroll metrics observed from [ScrollNotification]s.
  ScrollMetrics? lastMetrics;

  /// Whether the newest message's bottom edge is at the visual bottom of the
  /// viewport.
  ///
  /// Unlike checking `positions.any((p) => p.index == 0)` (which remains true
  /// as long as *any* pixel of a multi-screen streaming message is on screen),
  /// this checks that `index 0`'s bottom edge (`itemLeadingEdge`) is actually
  /// at the bottom of the viewport.
  bool isAtBottom(Iterable<ItemPosition> positions) {
    if (positions.isEmpty) return true;
    for (final p in positions) {
      if (p.index == 0) {
        return p.itemLeadingEdge >= bottomLeadingEdgeThreshold;
      }
    }
    return false;
  }

  /// Record a height change `delta` (`newHeight - oldHeight`) of a streaming
  /// bubble laid out in `GrowthDirection.forward`.
  void recordForwardExtentDelta(double delta) {
    if (delta.abs() < 0.5) return;
    if (isUserScrolledUp) {
      _pendingForwardExtentDelta += delta;
    } else {
      _pendingForwardExtentDelta = 0.0;
    }
  }

  /// Consume and clear the accumulated forward extent delta during
  /// [ChatStreamScrollPhysics.adjustPositionForNewDimensions].
  double consumeForwardExtentDelta() {
    final delta = _pendingForwardExtentDelta;
    _pendingForwardExtentDelta = 0.0;
    return delta;
  }

  void clearPendingDelta() {
    _pendingForwardExtentDelta = 0.0;
  }
}

/// Scroll physics that compensates scroll offset in-place during layout when a
/// streaming bubble grows below the user's scrolled-up viewport.
class ChatStreamScrollPhysics extends ScrollPhysics {
  final StreamingScrollAnchor anchor;

  const ChatStreamScrollPhysics({
    required this.anchor,
    super.parent,
  });

  @override
  ChatStreamScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return ChatStreamScrollPhysics(
      anchor: anchor,
      parent: buildParent(ancestor),
    );
  }

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final delta = anchor.consumeForwardExtentDelta();
    final base = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    if (anchor.isUserScrolledUp && delta != 0.0) {
      final compensated = base + delta;
      // Preserve overscroll if the user is actively pulling past bounds;
      // otherwise clamp to the updated scroll extents.
      if (oldPosition.pixels >= oldPosition.minScrollExtent &&
          oldPosition.pixels <= oldPosition.maxScrollExtent) {
        return compensated.clamp(
          newPosition.minScrollExtent,
          newPosition.maxScrollExtent,
        );
      }
      return compensated;
    }
    return base;
  }
}

/// Wraps a streaming message tile to observe layout-time height changes.
///
/// When the user is scrolled up, height deltas in `GrowthDirection.forward`
/// are fed into [StreamingScrollAnchor] and applied during the same viewport
/// layout pass. When the user is at the bottom, a post-frame
/// [SizeChangedLayoutNotification] is dispatched.
class StreamingSizeTracker extends SingleChildRenderObjectWidget {
  final StreamingScrollAnchor? anchor;

  const StreamingSizeTracker({
    super.key,
    this.anchor,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderStreamingSizeTracker(
      anchor: anchor,
      onLayoutSizeChanged: () {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            const SizeChangedLayoutNotification().dispatch(context);
          }
        });
      },
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderStreamingSizeTracker renderObject,
  ) {
    renderObject.anchor = anchor;
  }
}

class RenderStreamingSizeTracker extends RenderProxyBox {
  RenderStreamingSizeTracker({
    StreamingScrollAnchor? anchor,
    required VoidCallback onLayoutSizeChanged,
  })  : _anchor = anchor,
        _onLayoutSizeChanged = onLayoutSizeChanged;

  StreamingScrollAnchor? _anchor;
  StreamingScrollAnchor? get anchor => _anchor;
  set anchor(StreamingScrollAnchor? value) {
    if (identical(_anchor, value)) return;
    _anchor = value;
  }

  final VoidCallback _onLayoutSizeChanged;

  double? _previousHeight;
  double? _previousCrossAxisExtent;

  RenderSliver? _findEnclosingSliver() {
    RenderObject? node = parent;
    while (node != null) {
      if (node is RenderSliver) return node;
      node = node.parent;
    }
    return null;
  }

  RenderViewportBase? _findEnclosingViewport(RenderObject start) {
    RenderObject? node = start.parent;
    while (node != null) {
      if (node is RenderViewportBase) return node;
      node = node.parent;
    }
    return null;
  }

  @override
  void performLayout() {
    super.performLayout();
    final newHeight = size.height;
    final newCrossAxis = constraints.maxWidth;
    final prevHeight = _previousHeight;
    final prevCrossAxis = _previousCrossAxisExtent;
    _previousHeight = newHeight;
    _previousCrossAxisExtent = newCrossAxis;

    if (prevHeight == null || (newHeight - prevHeight).abs() < 0.5) {
      return;
    }

    // Ignore height changes caused by viewport width resize (e.g. window drag).
    if (prevCrossAxis != null && (newCrossAxis - prevCrossAxis).abs() >= 0.5) {
      return;
    }

    final delta = newHeight - prevHeight;
    final currentAnchor = _anchor;
    if (currentAnchor != null && currentAnchor.isUserScrolledUp) {
      final sliver = _findEnclosingSliver();
      if (sliver != null &&
          sliver.constraints.growthDirection == GrowthDirection.forward) {
        currentAnchor.recordForwardExtentDelta(delta);
        final viewport = _findEnclosingViewport(sliver);
        final offset = viewport?.offset;
        if (offset != null && offset.hasPixels) {
          // Flag the ScrollPosition as having received a layout-time correction
          // so applyContentDimensions is guaranteed to invoke
          // ChatStreamScrollPhysics.adjustPositionForNewDimensions in this pass.
          offset.correctBy(0.0);
        }
      }
      return;
    }

    _onLayoutSizeChanged();
  }
}
