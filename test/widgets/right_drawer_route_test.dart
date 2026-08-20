import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shepaw/utils/layout_utils.dart';
import 'package:shepaw/widgets/right_drawer_route.dart';

const _pageKey = Key('linked-home-page');
const _drawerKey = Key('drawer-content');
const _openButtonKey = Key('open-drawer');

/// 桌面尺寸（800x600）：抽屉宽 300，右对齐后占 500..800。
const _drawerWidth = 300.0;
const _screenWidth = 800.0;

/// 测试用共享控制器：与真实聊天页一致，同一控制器同时驱动抽屉路由
/// （showRightDrawer 的 sharedController，路由不销毁它）与页面联动
/// （RightDrawerLinkedPage）。
AnimationController _makeController() {
  final controller = AnimationController(
    vsync: const TestVSync(),
    duration: const Duration(milliseconds: 250),
  );
  addTearDown(controller.dispose);
  return controller;
}

/// 测试宿主：聊天页（RightDrawerLinkedPage 包裹）+ 打开按钮。
Widget _buildApp({
  required bool linked,
  required AnimationController controller,
}) {
  return MaterialApp(
    home: Builder(
      builder: (context) {
        Widget page = Scaffold(
          key: _pageKey,
          body: Center(
            child: Builder(
              builder: (context) {
                return ElevatedButton(
                  key: _openButtonKey,
                  onPressed: () => LayoutUtils.showRightDrawer<void>(
                    context: context,
                    width: _drawerWidth,
                    sharedController: controller,
                    builder: (_) =>
                        Container(key: _drawerKey, color: Colors.white),
                  ),
                  child: const Text('open'),
                );
              },
            ),
          ),
        );
        if (linked) {
          page = RightDrawerLinkedPage(
            width: _drawerWidth,
            animation: controller,
            child: page,
          );
        }
        return page;
      },
    ),
  );
}

/// 镜像 ChatMessageList 的结构：State 持有 GlobalKey 包住滚动视口。
/// 若宿主页面树被重挂（state 重建），此 key 是新的实例，旧视口无法被
/// 复取，滚动位置随之归零（reverse 列表即回到最底部）。
class _ProbeStatefulList extends StatefulWidget {
  const _ProbeStatefulList({required this.onInit, required this.child});

  final VoidCallback onInit;
  final Widget child;

  @override
  State<_ProbeStatefulList> createState() => _ProbeStatefulListState();
}

class _ProbeStatefulListState extends State<_ProbeStatefulList> {
  final GlobalKey _innerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(key: _innerKey, child: widget.child);
  }
}

void main() {
  testWidgets('renders right-aligned at given width', (tester) async {
    final controller = _makeController();
    await tester.pumpWidget(_buildApp(linked: false, controller: controller));
    await tester.tap(find.byKey(_openButtonKey));
    await tester.pumpAndSettle();

    final rect = tester.getRect(find.byKey(_drawerKey));
    expect(rect.left, _screenWidth - _drawerWidth);
    expect(rect.width, _drawerWidth);
  });

  testWidgets('barrier tap dismisses', (tester) async {
    final controller = _makeController();
    await tester.pumpWidget(_buildApp(linked: false, controller: controller));
    await tester.tap(find.byKey(_openButtonKey));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(100, 300));
    await tester.pumpAndSettle();
    expect(find.byKey(_drawerKey), findsNothing);
  });

  testWidgets('dismissed completes only after route disposal, not at pop',
      (tester) async {
    final controller = _makeController();
    late RightDrawerRoute<void> route;
    var dismissedCount = 0;
    var poppedCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: Builder(
                  builder: (context) {
                    return ElevatedButton(
                      onPressed: () {
                        route = LayoutUtils.showRightDrawer<void>(
                          context: context,
                          width: _drawerWidth,
                          sharedController: controller,
                          builder: (_) =>
                              Container(key: _drawerKey, color: Colors.white),
                        );
                        route.dismissed.then((_) => dismissedCount++);
                        route.popped.then((_) => poppedCount++);
                      },
                      child: const Text('open'),
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(_drawerKey), findsOneWidget);
    expect(dismissedCount, 0);
    expect(poppedCount, 0);

    // pop 瞬间：popped 立刻完成，但路由还在退场动画中，dismissed 未完成。
    Navigator.of(tester.element(find.byKey(_drawerKey)),
            rootNavigator: true)
        .pop();
    await tester.pump();
    expect(poppedCount, 1);
    expect(dismissedCount, 0);
    expect(find.byKey(_drawerKey), findsOneWidget);

    // 退场动画结束、路由销毁后 dismissed 才完成。
    await tester.pumpAndSettle();
    expect(dismissedCount, 1);
    expect(find.byKey(_drawerKey), findsNothing);
  });

  testWidgets('entrance animation keeps drawer and page in lockstep',
      (tester) async {
    final controller = _makeController();
    await tester.pumpWidget(_buildApp(linked: true, controller: controller));
    await tester.tap(find.byKey(_openButtonKey));
    // Ticker 首帧 elapsed 为 0：先 pump 一帧启动，再 pump 125ms 到中点。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 125));

    expect(
      tester.getRect(find.byKey(_drawerKey)).left,
      closeTo(_screenWidth - _drawerWidth + _drawerWidth * 0.5, 1),
    );
    expect(
      tester.getTopLeft(find.byKey(_pageKey)).dx,
      closeTo(-_drawerWidth * 0.5, 1),
    );

    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(_drawerKey)).left,
      _screenWidth - _drawerWidth,
    );
    expect(tester.getTopLeft(find.byKey(_pageKey)).dx, -_drawerWidth);

    // 关闭后页面回位。
    Navigator.of(tester.element(find.byKey(_openButtonKey)),
        rootNavigator: true)
        .pop();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(_pageKey)).dx, 0);
    expect(find.byKey(_drawerKey), findsNothing);
  });

  testWidgets('slow drag right past half closes', (tester) async {
    final controller = _makeController();
    await tester.pumpWidget(_buildApp(linked: true, controller: controller));
    await tester.tap(find.byKey(_openButtonKey));
    await tester.pumpAndSettle();

    // 拖 200px（> 半宽 150），低速使速度判定（>400px/s）不生效，走进度判定。
    await tester.timedDragFrom(
      const Offset(_screenWidth - _drawerWidth + 40, 300),
      const Offset(200, 0),
      const Duration(milliseconds: 800),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(_drawerKey), findsNothing);
  });

  testWidgets('small slow drag snaps back to open', (tester) async {
    final controller = _makeController();
    await tester.pumpWidget(_buildApp(linked: true, controller: controller));
    await tester.tap(find.byKey(_openButtonKey));
    await tester.pumpAndSettle();

    // 拖 80px（< 半宽），低速：进度 0.733 > 0.5 → 回弹到完全打开。
    await tester.timedDragFrom(
      const Offset(_screenWidth - _drawerWidth + 40, 300),
      const Offset(80, 0),
      const Duration(milliseconds: 800),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(_drawerKey), findsOneWidget);
    expect(
      tester.getRect(find.byKey(_drawerKey)).left,
      closeTo(_screenWidth - _drawerWidth, 1),
    );
  });

  testWidgets('gesture mode: handle drives progress, settle reopens then closes',
      (tester) async {
    final controller = _makeController();
    late RightDrawerHandle handle;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) {
                return ElevatedButton(
                  onPressed: () {
                    handle = RightDrawerHandle(width: _drawerWidth);
                    LayoutUtils.showRightDrawer<void>(
                      context: context,
                      width: _drawerWidth,
                      handle: handle,
                      initialProgress: 0.5,
                      sharedController: controller,
                      builder: (_) =>
                          Container(key: _drawerKey, color: Colors.white),
                    );
                  },
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    // 手势模式：推入不自动播放动画，直接停在 initialProgress 0.5。
    expect(handle.progress, closeTo(0.5, 0.001));
    expect(
      tester.getRect(find.byKey(_drawerKey)).left,
      closeTo(_screenWidth - _drawerWidth + _drawerWidth * 0.5, 1),
    );

    // 向左甩（<-400px/s）→ 回弹完全打开。
    handle.settle(velocityDx: -500);
    await tester.pumpAndSettle();
    expect(find.byKey(_drawerKey), findsOneWidget);
    expect(handle.progress, closeTo(1.0, 0.001));

    // 向右甩（>400px/s）→ 关闭。
    handle.settle(velocityDx: 500);
    await tester.pumpAndSettle();
    expect(find.byKey(_drawerKey), findsNothing);
  });

  testWidgets('open-gesture settle: partial progress with no flick stays open',
      (tester) async {
    // 回归：打开手势（handle.settle）曾沿用关闭手势的「进度 ≤ 半宽即关」，
    // 普通左滑（位移 10%~40% 宽度、抬手前已减速）推入后立即被 pop，
    // 表现为「闪一下又回去了」。
    final controller = _makeController();
    late RightDrawerHandle handle;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) {
                return ElevatedButton(
                  onPressed: () {
                    handle = RightDrawerHandle(width: _drawerWidth);
                    LayoutUtils.showRightDrawer<void>(
                      context: context,
                      width: _drawerWidth,
                      handle: handle,
                      initialProgress: 0.5,
                      sharedController: controller,
                      builder: (_) =>
                          Container(key: _drawerKey, color: Colors.white),
                    );
                  },
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();

    // 半进度、无甩动速度：旧逻辑 c.value <= 0.5 → pop（闪一下），新逻辑打开。
    handle.settle(velocityDx: 0);
    await tester.pumpAndSettle();
    expect(find.byKey(_drawerKey), findsOneWidget);
    expect(handle.progress, closeTo(1.0, 0.001));
  });

  testWidgets('open-gesture settle: low progress with no flick opens',
      (tester) async {
    // 常见左滑：只拖了 20% 宽度、抬手前手指减速到 ~0 速度 → 应回弹打开。
    final controller = _makeController();
    late RightDrawerHandle handle;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) {
                return ElevatedButton(
                  onPressed: () {
                    handle = RightDrawerHandle(width: _drawerWidth);
                    LayoutUtils.showRightDrawer<void>(
                      context: context,
                      width: _drawerWidth,
                      handle: handle,
                      initialProgress: 0.2,
                      sharedController: controller,
                      builder: (_) =>
                          Container(key: _drawerKey, color: Colors.white),
                    );
                  },
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    handle.settle(velocityDx: 0);
    await tester.pumpAndSettle();
    expect(find.byKey(_drawerKey), findsOneWidget);
    expect(handle.progress, closeTo(1.0, 0.001));
  });

  testWidgets('open-gesture settle: rightward reversal flick closes',
      (tester) async {
    // 左滑后明显向右甩（>400px/s，反悔）→ 关闭。
    final controller = _makeController();
    late RightDrawerHandle handle;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) {
                return ElevatedButton(
                  onPressed: () {
                    handle = RightDrawerHandle(width: _drawerWidth);
                    LayoutUtils.showRightDrawer<void>(
                      context: context,
                      width: _drawerWidth,
                      handle: handle,
                      initialProgress: 0.6,
                      sharedController: controller,
                      builder: (_) =>
                          Container(key: _drawerKey, color: Colors.white),
                    );
                  },
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    handle.settle(velocityDx: 500);
    await tester.pumpAndSettle();
    expect(find.byKey(_drawerKey), findsNothing);
  });

  testWidgets('open-gesture settle: micro swipe (no progress, no flick) opens',
      (tester) async {
    // 回归：低进度 + 零速度（旧逻辑「进度 <10% 且无左甩即关」）必须打开。
    // 识别器接受手势（位移超过 touchSlop/minOpenDistance 且横向主导）本身就
    // 是误触过滤；settle 的微滑判断只会误伤真实手势 —— 会话加载完成时 push
    // 抽屉路由触发 Navigator._cancelActivePointers，在途手指被取消（速度强制
    // 归零），任何加载完成于手势前段的真实短滑（边缘轻扫通常只有抽屉宽度
    // 的 3%~10%）都会命中「微滑」而被立即 pop，正是「闪一下又回去了」。
    final controller = _makeController();
    late RightDrawerHandle handle;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) {
                return ElevatedButton(
                  onPressed: () {
                    handle = RightDrawerHandle(width: _drawerWidth);
                    LayoutUtils.showRightDrawer<void>(
                      context: context,
                      width: _drawerWidth,
                      handle: handle,
                      initialProgress: 0.05,
                      sharedController: controller,
                      builder: (_) =>
                          Container(key: _drawerKey, color: Colors.white),
                    );
                  },
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    handle.settle(velocityDx: 0);
    await tester.pumpAndSettle();
    expect(find.byKey(_drawerKey), findsOneWidget);
    expect(handle.progress, closeTo(1.0, 0.001));
  });

  testWidgets('drawer open (animation crossing 0) keeps list scroll position',
      (tester) async {
    // 回归：RightDrawerLinkedPage 旧实现按 value 是否 >0 切换
    // child ↔ Transform(child) 两种树形，抽屉推入（共享控制器 0→0.3→1）
    // 时整个页面子树被重挂：ChatMessageList state 重建（其持有的 GlobalKey
    // 是新实例，旧视口无法复取），滚动视口从 initialScrollIndex 0 重建，
    // reverse 列表直接跳回最底部 —— 侧滑时聊天滚动条重置的根因。
    final controller = _makeController();
    final itemScrollController = ItemScrollController();
    final itemPositionsListener = ItemPositionsListener.create();
    var initCount = 0;

    Widget page = Scaffold(
      body: _ProbeStatefulList(
        onInit: () => initCount++,
        child: ScrollablePositionedList.builder(
          reverse: true,
          itemScrollController: itemScrollController,
          itemPositionsListener: itemPositionsListener,
          itemCount: 20,
          itemBuilder: (context, index) => SizedBox(
            height: 50,
            child: Center(child: Text('msg $index')),
          ),
        ),
      ),
    );
    page = RightDrawerLinkedPage(
      width: _drawerWidth,
      animation: controller,
      child: page,
    );
    await tester.pumpWidget(MaterialApp(home: page));
    expect(initCount, 1);

    // 先滚离底部（index 10），模拟用户翻阅历史消息后的状态。
    itemScrollController.jumpTo(index: 10);
    await tester.pumpAndSettle();
    final visibleBefore =
        itemPositionsListener.itemPositions.value.map((p) => p.index).toSet();
    expect(visibleBefore, contains(10));

    // 抽屉推入：手势模式 didPush 直接把共享控制器从 0 设为部分进度，
    // settle 再动画到全开（与聊天页打开抽屉一致）。
    controller.value = 0.3;
    await tester.pump();
    controller.animateTo(1.0, duration: const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    // 页面树不得重挂：列表 state 与滚动位置都必须保持。
    expect(initCount, 1, reason: 'linked page must not remount the page subtree');
    final visibleAfter =
        itemPositionsListener.itemPositions.value.map((p) => p.index).toSet();
    expect(visibleAfter, contains(10),
        reason: 'drawer open must not reset the chat scroll position');
  });

  testWidgets('linked page tracks handle progress directly', (tester) async {
    final controller = _makeController();
    late RightDrawerHandle handle;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            Widget page = Scaffold(
              key: _pageKey,
              body: Center(
                child: Builder(
                  builder: (context) {
                    return ElevatedButton(
                      onPressed: () {
                        handle = RightDrawerHandle(width: _drawerWidth);
                        LayoutUtils.showRightDrawer<void>(
                          context: context,
                          width: _drawerWidth,
                          handle: handle,
                          sharedController: controller,
                          builder: (_) =>
                              Container(key: _drawerKey, color: Colors.white),
                        );
                      },
                      child: const Text('open'),
                    );
                  },
                ),
              ),
            );
            return RightDrawerLinkedPage(
              width: _drawerWidth,
              animation: controller,
              child: page,
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(_pageKey)).dx, 0);

    handle.setProgress(0.5);
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(_pageKey)).dx,
      closeTo(-_drawerWidth * 0.5, 1),
    );

    handle.setProgress(1.0);
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(_pageKey)).dx, closeTo(-_drawerWidth, 1));
  });
}
