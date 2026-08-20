import 'dart:async';

import 'package:flutter/material.dart';

/// 右侧抽屉路由（替代 showGeneralDialog 实现聊天页「更多」侧滑菜单）。
///
/// 与普通 dialog route 的区别：
/// - **右滑关闭**：在抽屉面板或遮罩上向右拖动，抽屉（及联动页面）跟随手指，
///   松手时按进度与甩动速度决定关闭或回弹打开。
/// - **手势模式**（传入 [RightDrawerHandle]）：推入时不自动 forward，由打开
///   手势（[DrawerSwipeDetector] 的跟手回调）逐帧驱动进度，与关闭手势共用
///   同一进度源，保证抽屉与聊天页始终联动。
///
/// 页面联动：传 [sharedController] 时，本路由复用调用方持有的控制器（不再
/// 自建、不再负责销毁，见 `willDisposeAnimationController`）。调用方把同一
/// 控制器交给 [RightDrawerLinkedPage]，抽屉动画与页面平移即由同一进度源
/// 驱动 —— 打开动画、关闭动画、手势拖动期间页面都严格跟齐。注意不要依赖
/// `secondaryAnimation`：MaterialPageRoute 只会镜像 PageRoute 的进度，
/// 对 PopupRoute 类抽屉不生效。
class RightDrawerRoute<T> extends RawDialogRoute<T> {
  RightDrawerRoute({
    required this.builder,
    required this.width,
    this.handle,
    this.initialProgress = 0,
    this.dragToClose = true,
    this.sharedController,
    super.barrierLabel,
    super.settings,
  }) : super(
          pageBuilder: (context, animation, secondaryAnimation) {
            // 入场/退场用线性动画（不加曲线）：页面联动直接读同一控制器值，
            // 加曲线不会改变 controller.value，只会让本抽屉滑入曲线与页面
            // 平移脱节，故刻意保持线性。
            // 只包面板本身（300px）：SlideTransition 的位移基准是子组件
            // 宽度，包整个全屏 Align 会按 800px 计算，进度错一倍。
            return Align(
              alignment: Alignment.centerRight,
              child: SlideTransition(
                position:
                    Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero)
                        .animate(animation),
                child: Material(
                  elevation: 16,
                  child: SizedBox(
                    width: width,
                    height: MediaQuery.sizeOf(context).height,
                    child: SafeArea(child: builder(context)),
                  ),
                ),
              ),
            );
          },
          barrierDismissible: true,
          barrierColor: Colors.black54,
          transitionDuration: const Duration(milliseconds: 250),
        ) {
    if (sharedController != null) {
      // 控制器由调用方持有与销毁（路由 dispose 时只摘掉自己的监听）。
      willDisposeAnimationController = false;
    }
  }

  /// 调用方持有的共享控制器：传入时本路由复用（见 `willDisposeAnimationController`），
  /// 调用方把它同时交给 [RightDrawerLinkedPage]，抽屉动画与页面平移严格同源。
  final AnimationController? sharedController;

  /// 路由完全销毁（退场动画结束、overlay 移除）后完成的 future。
  ///
  /// 与 `popped`（pop 瞬间即完成）不同：pop 只代表开始退场，路由要等
  /// 退场动画播完、overlay 条目移除后才会 dispose。需要「抽屉彻底关闭」
  /// 的调用方应 await 它 —— 例如聊天页切换会话前：切换会销毁持有共享
  /// 动画控制器的页面（`sharedController` 随之 dispose），若抽屉还在退场
  /// 动画中就切换，退场永远无法完成，路由永不销毁，冻结在屏幕上。
  final Completer<void> _dismissedCompleter = Completer<void>();

  /// 见 [_dismissedCompleter] 注释。
  Future<void> get dismissed => _dismissedCompleter.future;

  /// 抽屉面板内容（由调用方构造，如 ChatMoreDrawer）。
  final WidgetBuilder builder;

  /// 抽屉宽度（px），调用方已 clamp 到屏幕宽度内。
  final double width;

  /// 传入时进入手势模式：推入不自动播放动画，由手势驱动进度。
  final RightDrawerHandle? handle;

  /// 手势模式推入瞬间的初始进度（0~1，手指已拖过的距离 / 宽度）。
  final double initialProgress;

  /// 是否允许在抽屉/遮罩上右滑关闭。默认开启。
  final bool dragToClose;

  bool get _gestureMode => handle != null;

  @override
  AnimationController createAnimationController() =>
      sharedController ?? super.createAnimationController();

  /// 一次拖动开始时的进度，用于把拖动位移换算为进度。
  double _dragStartValue = 1.0;

  /// 本次拖动累计位移（px，向右为正），按 _dragStartValue 换算进度。
  double _dragDx = 0;

  @override
  void install() {
    super.install();
    handle?.attach(this);
  }

  @override
  void dispose() {
    handle?.detach();
    if (!_dismissedCompleter.isCompleted) {
      _dismissedCompleter.complete();
    }
    super.dispose();
  }

  @override
  TickerFuture didPush() {
    if (!_gestureMode) return super.didPush();
    // 手势模式：跳过自动 forward（TransitionRoute.didPush 会 forward），
    // 按打开手势当前位置设置初始进度，之后由 setGestureProgress 逐帧驱动。
    controller?.value = initialProgress.clamp(0.0, 1.0);
    return TickerFuture.complete();
  }

  /// 手势驱动进度（0~1）：抽屉与下方联动页面同步跟随手指。
  void setGestureProgress(double progress) {
    controller?.value = progress.clamp(0.0, 1.0);
  }

  /// 当前打开进度（0~1），供 [RightDrawerHandle] 查询。
  double get progress => controller?.value ?? 0;

  /// 手势结束：按当前进度与甩动速度决定继续打开（回弹）或关闭。
  ///
  /// 明显向右甩（>400px/s）→ 关闭；明显向左甩（<-400px/s）→ 回弹打开；
  /// 其余按进度：过半打开，否则 pop（didPop 会从当前值 reverse 退出）。
  ///
  /// [opening] 表示本次手势是打开手势（聊天页左滑，经
  /// [RightDrawerHandle.settle] 收尾）而非关闭手势（抽屉/遮罩上右滑）：
  /// 打开手势已被识别器接受（位移超过最小打开距离），默认继续打开，仅在
  /// 明显反向甩动（向右 >400px/s）或几乎没拖动（进度 <10% 且无向左甩动，
  /// 属误触级微滑）时关闭。若沿用关闭手势的「进度 ≤ 半宽即关」判断，普通
  /// 左滑（位移通常只有抽屉宽度的 10%~40%，且抬手前手指已减速、速度远够
  /// 不到 400px/s）会在部分进度处被立即 pop —— 正是「闪一下又回去了」。
  void settleGesture({double velocityDx = 0, bool opening = false}) {
    final c = controller;
    if (c == null) return;
    final bool close;
    if (opening) {
      close = velocityDx > 400 || (c.value < 0.1 && velocityDx > -400);
    } else if (velocityDx > 400) {
      close = true; // 明显向右甩 → 关闭
    } else if (velocityDx < -400) {
      close = false; // 明显向左甩 → 继续打开
    } else {
      close = c.value <= 0.5;
    }
    if (close) {
      navigator?.pop(this);
    } else {
      c.animateTo(1.0, duration: transitionDuration);
    }
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 全屏手势：遮罩区域（联动页面露出部分）与抽屉面板上右滑都能关闭，
    // 与页面左滑打开手势共用同一进度，形成一体拖动的感觉。放在这里而非
    // pageBuilder，是因为这里能访问实例成员（控制器、settleGesture）。
    if (!dragToClose) return child;
    return GestureDetector(
      onHorizontalDragStart: (_) {
        _dragStartValue = controller?.value ?? 1.0;
        _dragDx = 0;
      },
      onHorizontalDragUpdate: (details) {
        final c = controller;
        if (c == null) return;
        // primaryDelta 是单次 move 的增量，须累计后再换算进度。
        _dragDx += details.primaryDelta ?? 0;
        c.value = (_dragStartValue - _dragDx / width).clamp(0.0, 1.0);
      },
      onHorizontalDragEnd: (details) =>
          settleGesture(velocityDx: details.primaryVelocity ?? 0),
      onHorizontalDragCancel: () => settleGesture(),
      child: child,
    );
  }
}

/// 抽屉打开手势（聊天页左滑）与关闭手势（抽屉右滑）共用的进度句柄。
///
/// 调用方在打开手势开始时创建并随 [showRightDrawer] 传入；路由推入后
/// attach。手势期间通过 [setProgress] 驱动抽屉进度，抬手时用 [settle] 收尾。
class RightDrawerHandle {
  RightDrawerHandle({required this.width});

  /// 抽屉宽度（px），用于把手指位移换算为进度。
  final double width;

  RightDrawerRoute? _route;

  /// 当前打开进度（0~1），route 尚未 attach 时为 0。
  double get progress => _route?.progress ?? 0;

  void attach(RightDrawerRoute route) => _route = route;

  void detach() => _route = null;

  /// 手指位移 → 进度：`位移 / width`，由路由 clamp 到 0~1。
  void setProgress(double progress) => _route?.setGestureProgress(progress);

  /// 抬手收尾：按当前进度与甩动速度决定回弹打开或关闭。
  ///
  /// 打开手势的收尾与关闭手势相反：默认继续打开，只有明显向右甩（反悔）
  /// 或误触级微滑才关闭（见 [RightDrawerRoute.settleGesture] 的 `opening`）。
  void settle({double velocityDx = 0}) =>
      _route?.settleGesture(velocityDx: velocityDx, opening: true);
}

/// 让页面随其上方的右侧抽屉路由联动：抽屉打开/关闭动画与手指拖动期间，
/// 本页同步向左平移（宽度 × 进度），形成抽屉与主页连为一体的效果。
///
/// 原理：页面与抽屉路由共用同一个 [animation]（见 `RightDrawerRoute` 的
/// `sharedController`），监听它即可逐帧同步 —— 包括手势直接写
/// `controller.value` 的值。注意不要改用 `ModalRoute.secondaryAnimation`：
/// MaterialPageRoute 只会镜像 PageRoute 的进度，对抽屉这类 PopupRoute
/// 不生效。
class RightDrawerLinkedPage extends StatelessWidget {
  const RightDrawerLinkedPage({
    super.key,
    required this.child,
    required this.width,
    required this.animation,
  });

  final Widget child;

  /// 抽屉宽度（px），与打开抽屉时传给 [LayoutUtils.showRightDrawer] 的一致。
  final double width;

  /// 抽屉打开进度（0~1），通常传与抽屉路由共享的控制器。
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        // 恒包一层 Transform（value=0 时位移为 0，纯 paint 无开销）：
        // 若按 value 是否 >0 切换 child ↔ Transform(child) 两种树形，抽屉
        // 推入/关闭（共享控制器跨过 0）会改变 builder 输出形状，整个页面
        // 子树被卸载重挂 —— ChatMessageList 持有的 GlobalKey 是 state 内
        // 新实例，旧滚动视口无法复取，视口从 initialScrollIndex 0 重建，
        // reverse 列表直接跳回最底部（侧滑时聊天滚动条重置）。
        return Transform.translate(
          offset: Offset(-width * animation.value, 0),
          child: child,
        );
      },
      child: child,
    );
  }
}
