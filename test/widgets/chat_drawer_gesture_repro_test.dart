import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shepaw/utils/layout_utils.dart';
import 'package:shepaw/widgets/drawer_swipe_detector.dart';
import 'package:shepaw/widgets/right_drawer_route.dart';

/// 复刻 chat_screen 的抽屉打开链路（跟手模式）：
/// DrawerSwipeDetector（聊天页参数）→ onOpenGestureStart → 异步加载会话
/// （可控延迟模拟 DB 查询）→ LayoutUtils.showRightDrawer(handle, sharedController)。
///
/// 目的：对比「加载快（新会话，无历史）」与「加载慢（有历史会话）」两种
/// 情况下，手指仍在屏幕上时 push 抽屉路由，抬手后抽屉是打开还是被 pop
/// （闪一下又回去）。
const _drawerKey = Key('drawer-content');
const _drawerWidth = 300.0;

/// 与 chat_screen 的 _chatDrawerOpenSwipeThreshold 一致的触发阈值。
const _openThreshold = 30.0;

class _ReproLog {
  final List<String> entries = <String>[];
  void add(String e) => entries.add(e);
  @override
  String toString() => entries.join('\n');
}

class _Host extends StatefulWidget {
  const _Host({
    required this.openDelay,
    required this.withMessageList,
    required this.log,
  });

  final Duration openDelay;
  final bool withMessageList;
  final _ReproLog log;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final AnimationController _drawerController;
  final _drawerGestureOpenDx = ValueNotifier<double>(0);
  double? _drawerGestureEndVelocity;
  RightDrawerHandle? _drawerHandle;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _drawerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
  }

  @override
  void dispose() {
    _drawerController.dispose();
    super.dispose();
  }

  Future<void> _startOpenDrawer(double gestureDx) async {
    if (_opening) return;
    _opening = true;
    widget.log.add('openStart(dx=$gestureDx)');
    await Future<void>.delayed(widget.openDelay); // 模拟会话加载
    if (!mounted) return;
    widget.log.add('push(openDx=${_drawerGestureOpenDx.value})');
    final handle = RightDrawerHandle(
      width: _drawerWidth,
      openThreshold: _openThreshold,
    );
    _drawerHandle = handle;
    final route = LayoutUtils.showRightDrawer<void>(
      context: context,
      width: _drawerWidth,
      handle: handle,
      initialProgress:
          (_drawerGestureOpenDx.value / _drawerWidth).clamp(0.0, 1.0),
      sharedController: _drawerController,
      builder: (_) => Container(key: _drawerKey, color: Colors.white),
    );
    final endVelocity = _drawerGestureEndVelocity;
    if (endVelocity != null) {
      widget.log.add('settle(stored v=$endVelocity)');
      handle.settle(
        velocityDx: endVelocity,
        openDx: _drawerGestureOpenDx.value,
      );
      _drawerGestureEndVelocity = null;
    }
    await route.dismissed;
    _drawerHandle = null;
    _opening = false;
  }

  void _onOpenGestureStart(double openDx) {
    _drawerGestureOpenDx.value = openDx;
    _drawerGestureEndVelocity = null;
    unawaited(_startOpenDrawer(openDx));
  }

  void _onOpenGestureUpdate(double openDx) {
    _drawerGestureOpenDx.value = openDx;
    final handle = _drawerHandle;
    if (handle != null) {
      handle.setProgress(openDx / handle.width);
    }
  }

  void _onOpenGestureEnd(double velocityDx, double openDx) {
    widget.log.add('openEnd(v=$velocityDx, dx=$openDx)');
    _drawerGestureOpenDx.value = openDx;
    final handle = _drawerHandle;
    if (handle != null) {
      widget.log.add('settle(live v=$velocityDx, dx=$openDx)');
      handle.settle(velocityDx: velocityDx, openDx: openDx);
    } else {
      _drawerGestureEndVelocity = velocityDx;
    }
  }

  @override
  Widget build(BuildContext context) {
    return RightDrawerLinkedPage(
      width: _drawerWidth,
      animation: _drawerController,
      child: Scaffold(
        body: DrawerSwipeDetector(
          enabled: true,
          touchSlop: 8,
          minOpenDistance: _openThreshold,
          horizontalDominance: 1.0,
          verticalDominance: 2.0,
          direction: DrawerSwipeDirection.rightToLeft,
          onOpenGestureStart: _onOpenGestureStart,
          onOpenGestureUpdate: _onOpenGestureUpdate,
          onOpenGestureEnd: _onOpenGestureEnd,
          child: widget.withMessageList
              ? ScrollablePositionedList.builder(
                  reverse: true,
                  itemCount: 50,
                  itemBuilder: (context, index) => Container(
                    height: 56,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('message $index'),
                  ),
                )
              : const Center(child: Text('empty session')),
        ),
      ),
    );
  }
}

Future<void> _pumpHost(
  WidgetTester tester, {
  required Duration openDelay,
  required bool withMessageList,
  required _ReproLog log,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: _Host(
      openDelay: openDelay,
      withMessageList: withMessageList,
      log: log,
    ),
  ));
  await tester.pump();
}

/// 完成一次左滑：down → 若干 move（每步 pump 一帧）→ up。
Future<TestGesture> _swipe(
  WidgetTester tester, {
  required double startDx,
  required double endDx,
  required double dy,
  int steps = 8,
}) async {
  final gesture = await tester.startGesture(Offset(startDx, dy));
  for (var i = 1; i <= steps; i++) {
    final dx = startDx - (startDx - endDx) * i / steps;
    await gesture.moveTo(Offset(dx, dy));
    await tester.pump(const Duration(milliseconds: 16));
  }
  return gesture;
}

void main() {
  // 场景 A：空会话（加载快）。会话查询在手指抬起前完成，push 发生在
  // 手势早期（进度很小）—— 旧行为：push 瞬间 cancel 指针，
  // settle(0) 按「进度 <10% 即关」直接 pop。
  testWidgets('A: fast load — drawer ends open', (tester) async {
    final log = _ReproLog();
    await _pumpHost(
      tester,
      openDelay: Duration.zero,
      withMessageList: false,
      log: log,
    );

    final gesture = await _swipe(tester,
        startDx: 360, endDx: 240, dy: 400);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byKey(_drawerKey), findsOneWidget,
        reason: '空会话快速加载：抽屉应保持打开\n$log');
  });

  // 场景 B：有历史会话（加载慢）。push 发生手势中段，随后手指继续滑动、
  // 抬手。旧行为：push 的 _cancelActivePointers 取消手指 → velocity=0 →
  // settle(0) 若进度 <10% 直接 pop（闪一下又回去）。
  testWidgets('B: slow load, lift after push — drawer ends open',
      (tester) async {
    final log = _ReproLog();
    await _pumpHost(
      tester,
      openDelay: const Duration(milliseconds: 200),
      withMessageList: true,
      log: log,
    );

    final gesture = await _swipe(tester,
        startDx: 360, endDx: 240, dy: 400);
    // 等加载完成（push 发生）再抬手。
    await tester.pump(const Duration(milliseconds: 250));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byKey(_drawerKey), findsOneWidget,
        reason: '加载完成前手指未抬起：抽屉应保持打开\n$log');
  });

  // 场景 C：有历史会话（加载慢），但手指在 push 前已抬手 ——
  // 应使用抬手时的真实速度 settle。
  testWidgets('C: slow load, lift before push — drawer ends open',
      (tester) async {
    final log = _ReproLog();
    await _pumpHost(
      tester,
      openDelay: const Duration(milliseconds: 200),
      withMessageList: true,
      log: log,
    );

    final gesture = await _swipe(tester,
        startDx: 360, endDx: 240, dy: 400);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    expect(find.byKey(_drawerKey), findsOneWidget,
        reason: '抬手早于加载完成：用抬手速度 settle，应打开\n$log');
  });

  // 场景 D：短滑（20px < 触发阈值 30px）。旧配置 8px 阈值会接受这种短滑
  // 并「闪一下又回去」；新阈值下识别器根本不会接受，抽屉不出现。
  testWidgets('D: below-threshold swipe never opens the drawer',
      (tester) async {
    final log = _ReproLog();
    await _pumpHost(
      tester,
      openDelay: const Duration(milliseconds: 100),
      withMessageList: true,
      log: log,
    );

    final gesture = await _swipe(tester,
        startDx: 360, endDx: 340, dy: 400);
    await tester.pump(const Duration(milliseconds: 150));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byKey(_drawerKey), findsNothing,
        reason: '低于触发阈值的短滑不应触发抽屉\n$log');
  });

  // 场景 E：越过阈值（40px）的慢速短滑。加载完成 push 打断在途手指
  // （PointerCancel，速度归零），但 openDx 仍 ≥ 阈值 → 继续打开，
  // 「闪一下又回去」不再复现（9f306a0 的回归锚点，阈值改为 30px 后）。
  testWidgets('E: threshold-crossing slow swipe — drawer stays open (no flash)',
      (tester) async {
    final log = _ReproLog();
    await _pumpHost(
      tester,
      openDelay: const Duration(milliseconds: 100),
      withMessageList: true,
      log: log,
    );

    final gesture = await _swipe(tester,
        startDx: 360, endDx: 320, dy: 400);
    await tester.pump(const Duration(milliseconds: 150));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byKey(_drawerKey), findsOneWidget,
        reason: '越过阈值后被 push 打断的短滑不应闪退\n$log');
  });

  // 场景 F：打开手势后手指向右滑回（openDx 缩回 30px 阈值之下），抽屉
  // 跟随回位；加载完成 push 打断在途手指时按阈值规则关闭（不是默认打开）。
  testWidgets('F: slide back below threshold — drawer follows back and closes',
      (tester) async {
    final log = _ReproLog();
    await _pumpHost(
      tester,
      openDelay: const Duration(milliseconds: 400),
      withMessageList: true,
      log: log,
    );

    final gesture = await _swipe(tester,
        startDx: 360, endDx: 300, dy: 400); // 左滑 60px → 越过阈值
    // 向右回滑 40px（慢速，速度 < 400px/s）：openDx = 20 < 阈值。
    for (var i = 1; i <= 4; i++) {
      await gesture.moveTo(Offset(300 + i * 10, 400));
      await tester.pump(const Duration(milliseconds: 32));
    }
    // 等加载完成：push 打断在途手指时 openDx 已缩回阈值之下 → 关闭。
    await tester.pump(const Duration(milliseconds: 450));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byKey(_drawerKey), findsNothing,
        reason: '滑回去后抽屉应跟着回去并关闭\n$log');
  });
}
