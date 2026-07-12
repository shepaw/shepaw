import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Pins [header] to the top of this widget's visible area inside its
/// scrollable ancestor. When the item scrolls out of view, the header
/// leaves with it (clamped to the item bottom).
///
/// The header is always painted above [child] so the bubble never covers
/// the author chrome while stuck.
///
/// When [showHeaderInFlow] is false, the header only appears while stuck
/// (consecutive group messages).
class StickyInViewHeader extends StatefulWidget {
  final Widget header;
  final Widget child;
  final bool enabled;
  final bool showHeaderInFlow;
  final Color? stuckBackground;
  final List<Listenable> scrollListenables;

  /// Optional list viewport box used for Y measurement. Prefer this over
  /// walking to [Scrollable] — more reliable with ScrollablePositionedList.
  final GlobalKey? viewportKey;

  const StickyInViewHeader({
    super.key,
    required this.header,
    required this.child,
    this.enabled = true,
    this.showHeaderInFlow = true,
    this.stuckBackground,
    this.scrollListenables = const [],
    this.viewportKey,
  });

  @override
  State<StickyInViewHeader> createState() => _StickyInViewHeaderState();
}

class _StickyInViewHeaderState extends State<StickyInViewHeader> {
  final GlobalKey _headerKey = GlobalKey();
  ScrollPosition? _position;
  double _stuckOffset = 0;
  double _headerHeight = 36;
  bool _frameScheduled = false;

  bool get _isStuck => _stuckOffset > 0.5;

  @override
  void initState() {
    super.initState();
    for (final l in widget.scrollListenables) {
      l.addListener(_scheduleUpdate);
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
        l.removeListener(_scheduleUpdate);
      }
      for (final l in widget.scrollListenables) {
        l.addListener(_scheduleUpdate);
      }
    }
  }

  @override
  void dispose() {
    _position?.removeListener(_scheduleUpdate);
    for (final l in widget.scrollListenables) {
      l.removeListener(_scheduleUpdate);
    }
    super.dispose();
  }

  void _attachPosition() {
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _position)) {
      _position?.removeListener(_scheduleUpdate);
      _position = position;
      _position?.addListener(_scheduleUpdate);
    }
  }

  void _scheduleUpdate() {
    if (_frameScheduled || !mounted) return;
    _frameScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _frameScheduled = false;
      _recalculate();
    });
  }

  void _recalculate() {
    if (!widget.enabled || !mounted) return;

    final itemBox = context.findRenderObject() as RenderBox?;
    if (itemBox == null || !itemBox.hasSize) return;

    final headerBox =
        _headerKey.currentContext?.findRenderObject() as RenderBox?;
    final headerHeight =
        headerBox != null && headerBox.hasSize ? headerBox.size.height : 36.0;

    final itemTop = _itemTopInViewport(itemBox);
    if (itemTop == null) return;

    double offset = 0;
    if (itemTop < 0) {
      final maxOffset = math.max(0.0, itemBox.size.height - headerHeight);
      offset = (-itemTop).clamp(0.0, maxOffset);
    }

    final heightChanged = (headerHeight - _headerHeight).abs() > 0.5;
    final offsetChanged = (offset - _stuckOffset).abs() > 0.5;
    if (heightChanged || offsetChanged) {
      setState(() {
        _headerHeight = headerHeight;
        _stuckOffset = offset;
      });
    }
  }

  double? _itemTopInViewport(RenderBox itemBox) {
    final itemGlobal = itemBox.localToGlobal(Offset.zero);

    final viewportKeyBox =
        widget.viewportKey?.currentContext?.findRenderObject() as RenderBox?;
    if (viewportKeyBox != null && viewportKeyBox.hasSize) {
      return itemGlobal.dy - viewportKeyBox.localToGlobal(Offset.zero).dy;
    }

    final scrollable = Scrollable.maybeOf(context);
    final scrollableBox = scrollable?.context.findRenderObject() as RenderBox?;
    if (scrollableBox == null || !scrollableBox.hasSize) return null;

    return itemGlobal.dy - scrollableBox.localToGlobal(Offset.zero).dy;
  }

  Widget _buildHeader(BuildContext context) {
    final stuck = _isStuck;
    final bg = widget.stuckBackground ??
        Theme.of(context).scaffoldBackgroundColor;
    return KeyedSubtree(
      key: _headerKey,
      child: Material(
        // Always opaque while stuck so bubble text never shows through.
        color: stuck ? bg : Colors.transparent,
        elevation: 0,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: stuck ? bg : null,
            border: stuck
                ? Border(
                    bottom: BorderSide(
                      color: Colors.grey.withValues(alpha: 0.25),
                      width: 0.5,
                    ),
                  )
                : null,
          ),
          child: widget.header,
        ),
      ),
    );
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

    _scheduleUpdate();
    final header = _buildHeader(context);

    // Overlay-only: header appears above the bubble only while stuck.
    if (!widget.showHeaderInFlow) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (_isStuck)
            Positioned(
              top: _stuckOffset,
              left: 0,
              right: 0,
              child: header,
            )
          else
            Offstage(child: header),
        ],
      );
    }

    // In-flow: reserve header height, paint the real header last so it
    // always sits above the bubble while stuck.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: EdgeInsets.only(top: _headerHeight),
          child: widget.child,
        ),
        Positioned(
          top: _stuckOffset,
          left: 0,
          right: 0,
          child: header,
        ),
      ],
    );
  }
}
