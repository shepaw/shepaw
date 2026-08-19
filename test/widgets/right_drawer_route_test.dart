import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
