import 'package:flutter/material.dart';

/// Expands drawer open gestures beyond the default narrow edge strip.
///
/// Detects rightward drags that start within [edgeWidth] of the left screen
/// edge and opens the scaffold drawer when the drag distance exceeds
/// [minDragDistance].
class DrawerSwipeDetector extends StatefulWidget {
  const DrawerSwipeDetector({
    super.key,
    required this.child,
    this.enabled = true,
    this.edgeWidth = 72,
    this.minDragDistance = 56,
  });

  final Widget child;
  final bool enabled;
  final double edgeWidth;
  final double minDragDistance;

  @override
  State<DrawerSwipeDetector> createState() => _DrawerSwipeDetectorState();
}

class _DrawerSwipeDetectorState extends State<DrawerSwipeDetector> {
  double? _startX;
  double _totalDx = 0;
  bool _opened = false;

  void _reset() {
    _startX = null;
    _totalDx = 0;
    _opened = false;
  }

  void _handleDragUpdate(double dx) {
    if (!widget.enabled || _opened || _startX == null) return;
    if (_startX! > widget.edgeWidth) return;

    _totalDx += dx;
    if (_totalDx < widget.minDragDistance) return;

    final scaffold = Scaffold.maybeOf(context);
    if (scaffold == null || !scaffold.hasDrawer) return;

    scaffold.openDrawer();
    _opened = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _startX = event.position.dx;
        _totalDx = 0;
        _opened = false;
      },
      onPointerMove: (event) => _handleDragUpdate(event.delta.dx),
      onPointerUp: (_) => _reset(),
      onPointerCancel: (_) => _reset(),
      child: widget.child,
    );
  }
}
