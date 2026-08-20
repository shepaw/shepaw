import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, RenderEditable, RenderViewportBase;

/// Decision for a candidate drawer-open swipe while a pointer is moving.
@visibleForTesting
enum DrawerSwipeDecision {
  /// Not enough movement yet, or still ambiguous.
  wait,

  /// Movement is clearly vertical-dominant (dy well above dx, default
  /// > 2×dx); yield immediately so list scrolling can win.
  rejectAsVertical,

  /// Movement is a clear open gesture in the configured direction.
  acceptOpen,

  /// Movement is clearly horizontal but not an open swipe in the
  /// configured direction.
  rejectAsHorizontal,
}

/// 抽屉打开滑动方向：主页左侧抽屉向右滑，聊天页右侧抽屉向左滑。
enum DrawerSwipeDirection {
  /// 向右滑打开（主页左侧抽屉）。
  leftToRight,

  /// 向左滑打开（聊天页右侧抽屉）。
  rightToLeft,
}

/// Pure disambiguation used by [_DrawerOpenSwipeRecognizer].
///
/// List scrolling wins when movement is clearly vertical past [touchSlop]
/// (dy > [verticalDominance]×dx, i.e. steeper than ~63°). A drawer open is
/// accepted when the swipe is directional (rightward for
/// [DrawerSwipeDirection.leftToRight], leftward for
/// [DrawerSwipeDirection.rightToLeft]) past [minOpenDistance].
///
/// 45°–63° 的斜向滑动既不立即拒绝也不接受（`wait`）：最终让位给列表滚动
/// （36px）或 SelectionArea（|dx|>18），避免把真实手指/模拟器上带垂直分量
/// 的打开手势误杀 —— 真实滑动几乎不可能完全水平，旧的「dy ≥ dx 即拒」
/// 会让 dy/dx 略大于 1 的手势在 Android 上被 SelectionArea 抢先、iOS 上
/// 被列表 36px 阈值抢先，抽屉基本滑不出来。
@visibleForTesting
DrawerSwipeDecision decideDrawerSwipe({
  required double dx,
  required double dy,
  DrawerSwipeDirection direction = DrawerSwipeDirection.leftToRight,
  double touchSlop = kTouchSlop,
  double horizontalDominance = 1.25,
  double verticalDominance = 2.0,
  double minOpenDistance = 36,
}) {
  final absDx = dx.abs();
  final absDy = dy.abs();
  final distance = Offset(dx, dy).distance;
  if (distance < touchSlop) {
    return DrawerSwipeDecision.wait;
  }

  // Movement along the open direction (right for left drawer, left for
  // right drawer); opposite direction is not an open gesture.
  final openDx = direction == DrawerSwipeDirection.leftToRight ? dx : -dx;
  if (openDx <= 0) {
    return DrawerSwipeDecision.rejectAsHorizontal;
  }

  // Vertical priority: as soon as up/down clearly dominates (not just
  // slightly — real open swipes carry vertical drift), give up so list
  // scrolling wins instantly.
  if (absDy > absDx * verticalDominance) {
    return DrawerSwipeDecision.rejectAsVertical;
  }

  // Need a clear horizontal bias before claiming the arena.
  if (openDx < absDy * horizontalDominance) {
    return DrawerSwipeDecision.wait;
  }

  if (openDx >= minOpenDistance) {
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
/// 跟手模式：提供 [onOpenGestureStart] 时，识别成功后不再触发 [onOpenDrawer]，
/// 而是持续上报打开方向上的位移（[onOpenGestureUpdate]）直到抬手
/// （[onOpenGestureEnd] 带甩动速度），调用方用其驱动抽屉路由的进度
/// （见 `RightDrawerRoute`），实现抽屉与页面跟随手指。
///
/// 与气泡/输入框共存：聊天页把 [touchSlop]/[minOpenDistance] 压到
/// SelectionArea 的 touchSlop（18px）之下，气泡上的左滑即可打开抽屉；同时
/// down 时命中横向可滚动区或可编辑文本会自动让位（见
/// [_DrawerOpenSwipeRecognizer._hasOwnedHorizontalGestureAt]），横向滚动与
/// 拖选不受影响。
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
    this.onOpenGestureStart,
    this.onOpenGestureUpdate,
    this.onOpenGestureEnd,
    this.direction = DrawerSwipeDirection.leftToRight,
    this.verticalScrollSlop = 18,
    this.blockLeadingEdgeDrawerGesture = false,
    this.leadingEdgeBlockWidth,
    this.touchSlop = kTouchSlop,
    this.horizontalDominance = 1.25,
    this.verticalDominance = 2.0,
    this.minOpenDistance = 36,
  });

  final Widget child;
  final bool enabled;

  /// Opens the drawer when a clear swipe in [direction] is recognized.
  /// Defaults to rightward (home's left drawer); chat pages pass
  /// [DrawerSwipeDirection.rightToLeft] for the right-side drawer.
  final VoidCallback? onOpenDrawer;

  /// 跟手打开模式的入口：提供时识别成功后不再触发 [onOpenDrawer]，
  /// 改以 [onOpenGestureStart] / [onOpenGestureUpdate] / [onOpenGestureEnd]
  /// 持续上报打开方向上的累计位移（px，左滑打开时为正值）直到抬手。
  final ValueChanged<double>? onOpenGestureStart;

  /// 识别成功后逐帧上报的打开位移（px）。
  final ValueChanged<double>? onOpenGestureUpdate;

  /// 抬手瞬间：横向速度（px/s，向右为正）与最终打开位移（px）。
  final void Function(double velocityDx, double openDx)? onOpenGestureEnd;

  /// 打开抽屉的滑动方向：主页左侧抽屉右滑，聊天页右侧抽屉左滑。
  final DrawerSwipeDirection direction;

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
  final double verticalDominance;
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

    if (onOpenDrawer != null || onOpenGestureStart != null) {
      result = RawGestureDetector(
        // opaque：识别器全区域参与竞技场。默认 deferToChild 下，指针落在
        // 无可命中子组件的区域（如空聊天页的空白处、内容间的空隙）时路径里
        // 没有本监听器，识别器根本收不到 down 事件，左滑无响应。
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          _DrawerOpenSwipeRecognizer:
              GestureRecognizerFactoryWithHandlers<_DrawerOpenSwipeRecognizer>(
            () => _DrawerOpenSwipeRecognizer(
              direction: direction,
              touchSlop: touchSlop,
              horizontalDominance: horizontalDominance,
              verticalDominance: verticalDominance,
              minOpenDistance: minOpenDistance,
              blockedLeadingWidth: leadingBlock,
              onOpenGestureStart: onOpenGestureStart,
              onOpenGestureUpdate: onOpenGestureUpdate,
              onOpenGestureEnd: onOpenGestureEnd,
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
    required this.direction,
    required this.touchSlop,
    required this.horizontalDominance,
    required this.verticalDominance,
    required this.minOpenDistance,
    required this.blockedLeadingWidth,
    this.onOpenGestureStart,
    this.onOpenGestureUpdate,
    this.onOpenGestureEnd,
  });

  final DrawerSwipeDirection direction;
  final double touchSlop;
  final double horizontalDominance;
  final double verticalDominance;
  final double minOpenDistance;
  final double blockedLeadingWidth;

  VoidCallback? onOpen;

  final ValueChanged<double>? onOpenGestureStart;
  final ValueChanged<double>? onOpenGestureUpdate;
  final void Function(double velocityDx, double openDx)? onOpenGestureEnd;

  /// 跟手模式：识别成功后持续上报位移，直到抬手。
  bool get _gestureMode => onOpenGestureStart != null;

  /// 打开方向上的累计位移（左滑打开时为正值）。
  double get _openDx =>
      direction == DrawerSwipeDirection.leftToRight ? _offset.dx : -_offset.dx;

  Offset _offset = Offset.zero;

  /// 已作出判定（接受或拒绝）：不再继续裁决。
  bool _resolved = false;

  /// 判定为打开手势并正在跟手上报（仅手势模式为 true）。
  bool _accepted = false;

  /// 手指速度估算（PointerMoveEvent 不带 velocity，抬手时用它算甩动方向）。
  late VelocityTracker _velocityTracker;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (blockedLeadingWidth > 0 && event.position.dx <= blockedLeadingWidth) {
      return;
    }
    // 手指落在「自带横向手势」的控件（横向可滚动区、可编辑文本）上时直接
    // 让位：它们的拖拽识别器在 touchSlop(18px) 就无条件接受竞技场（见
    // tap_and_drag.dart 的 _hasSufficientGlobalDistanceToAccept）。若不先让位，
    // 气泡内代码块的横向滚动、输入框的拖选会被抢先接受的抽屉手势抢走。
    if (_hasOwnedHorizontalGestureAt(event.position, event.viewId)) {
      return;
    }
    _offset = Offset.zero;
    _resolved = false;
    _accepted = false;
    _velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    startTrackingPointer(event.pointer, event.transform);
  }

  /// 手指下方是否命中「自带横向手势」的控件：横向可滚动区域或可编辑文本。
  ///
  /// 在 down 时（竞技场未分胜负前）独立 hit test 一次。命中则本识别器不
  /// 加入竞技场，把指针完整让给下方控件 —— 气泡内代码块的横向滚动、输入
  /// 框的拖选等永远优先于抽屉打开手势；正因如此，聊天页才能把识别阈值
  /// 压到 SelectionArea 的 18px 之下（见 chat_screen 的 touchSlop/minOpenDistance）。
  bool _hasOwnedHorizontalGestureAt(Offset position, int viewId) {
    final result = HitTestResult();
    GestureBinding.instance.hitTestInView(result, position, viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderEditable) {
        return true;
      }
      // ListView / PageView / 横向附件条等：RenderViewportBase 公开 axisDirection。
      if (target is RenderViewportBase && _isHorizontalAxis(target.axisDirection)) {
        return true;
      }
      // SingleChildScrollView 的 _RenderSingleChildViewport 是私有类，但公开
      // 实现 RenderAbstractViewport 接口且带公开的 axisDirection getter，
      // 借 dynamic 读取（命中此分支的只可能是它）。
      if (target is RenderBox && target is RenderAbstractViewport) {
        final direction = (target as dynamic).axisDirection as AxisDirection;
        if (_isHorizontalAxis(direction)) return true;
      }
    }
    return false;
  }

  static bool _isHorizontalAxis(AxisDirection direction) =>
      direction == AxisDirection.left || direction == AxisDirection.right;

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _offset += event.delta;
      _velocityTracker.addPosition(event.timeStamp, event.position);
      if (_resolved) {
        // 已判定：只有接受为打开手势才继续上报位移，让抽屉跟随手指；
        // 拒绝（让位给列表滚动等）后不再上报。
        if (_accepted) {
          onOpenGestureUpdate?.call(_openDx);
        }
        return;
      }
      switch (decideDrawerSwipe(
        dx: _offset.dx,
        dy: _offset.dy,
        direction: direction,
        touchSlop: touchSlop,
        horizontalDominance: horizontalDominance,
        verticalDominance: verticalDominance,
        minOpenDistance: minOpenDistance,
      )) {
        case DrawerSwipeDecision.wait:
          break;
        case DrawerSwipeDecision.rejectAsVertical:
        case DrawerSwipeDecision.rejectAsHorizontal:
          _resolved = true;
          resolve(GestureDisposition.rejected);
          break;
        case DrawerSwipeDecision.acceptOpen:
          _resolved = true;
          _accepted = true;
          resolve(GestureDisposition.accepted);
          if (_gestureMode) {
            onOpenGestureStart?.call(_openDx);
          } else {
            onOpen?.call();
          }
          break;
      }
      return;
    }

    if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_resolved) {
        if (_accepted && _gestureMode) {
          // PointerUpEvent 不带 velocity：用 VelocityTracker 估算；cancel 视为 0。
          final velocity = event is PointerUpEvent
              ? _velocityTracker.getVelocity().pixelsPerSecond.dx
              : 0.0;
          onOpenGestureEnd?.call(velocity, _openDx);
        }
      } else {
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
