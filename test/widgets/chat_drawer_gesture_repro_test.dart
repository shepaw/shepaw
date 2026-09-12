import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shepaw/utils/layout_utils.dart';
import 'package:shepaw/widgets/drawer_swipe_detector.dart';
import 'package:shepaw/widgets/right_drawer_route.dart';

/// 复刻 chat_screen 的抽屉打开链路（跟手模式）：
/// DrawerSwipeDetector（聊天页参数）→ onOpenGestureStart → **先弹后填**
/// （手势被接受那一帧同步建 handle、推路由，会话内容稍后填入，可控延迟
/// 模拟 DB 查询）→ LayoutUtils.showRightDrawer(handle, sharedController)。
///
/// 链路与 chat_screen 的 `_openSessionDrawer` 保持一致：push 不再等会话查询。
/// 旧链路（先 await 查询、再 push）把「等数据」的空窗暴露成手指在动、抽屉
/// 不动，然后一次性弹出。
///
/// 由此带来的两个行为变化，由场景 C/F 固定下来：
/// 1. 抽屉的手势进度永远停在「被接受的那一帧」——`NavigatorState.push`
///    结尾的 `_cancelActivePointers` 会把在途手指取消，识别器随即以
///    `velocity = 0`、`openDx = 接受帧位移` 上报 onOpenGestureEnd
///    （见 drawer_swipe_detector.dart 的 PointerCancelEvent 分支）。
/// 2. 因此「越过阈值后往回滑取消打开」的路径不复存在：往回滑的 move 事件
///    再也送不到识别器。旧链路下它也只是在查询慢到跨过抬手时才偶然生效。
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
  RightDrawerHandle? _drawerHandle;
  bool _opening = false;

  /// 面板内容条数（先弹后填：首帧 0 条，加载完成后原地替换为 5 条）。
  final _sessionCount = ValueNotifier<int>(0);

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
    _sessionCount.dispose();
    _drawerController.dispose();
    super.dispose();
  }

  /// 先弹后填：同步建 handle、推路由（抽屉立刻出现在手指位置），内容随后
  /// 由 [widget.openDelay] 模拟的查询结果填入。对应 chat_screen 的
  /// `_openSessionDrawer`。
  void _startOpenDrawer(double gestureDx) {
    if (_opening) return;
    _opening = true;
    widget.log.add('push(openDx=$gestureDx)');
    final handle = RightDrawerHandle(
      width: _drawerWidth,
      openThreshold: _openThreshold,
    );
    _drawerHandle = handle;
    final route = LayoutUtils.showRightDrawer<void>(
      context: context,
      width: _drawerWidth,
      handle: handle,
      initialProgress: (gestureDx / _drawerWidth).clamp(0.0, 1.0),
      sharedController: _drawerController,
      builder: (_) => ValueListenableBuilder<int>(
        valueListenable: _sessionCount,
        builder: (context, count, _) => Container(
          key: _drawerKey,
          color: Colors.white,
          alignment: Alignment.center,
          child: Text('sessions: $count'),
        ),
      ),
    );
    unawaited(() async {
      await Future<void>.delayed(widget.openDelay); // 模拟会话查询
      widget.log.add('loaded');
      if (mounted) _sessionCount.value = 5;
      await route.dismissed;
      _drawerHandle = null;
      _opening = false;
    }());
  }

  void _onOpenGestureStart(double openDx) {
    _startOpenDrawer(openDx);
  }

  void _onOpenGestureUpdate(double openDx) {
    // push 会立刻取消在途指针，这里通常到不了；保留以对齐 chat_screen。
    final handle = _drawerHandle;
    if (handle != null) {
      handle.setProgress(openDx / handle.width);
    }
  }

  void _onOpenGestureEnd(double velocityDx, double openDx) {
    widget.log.add('openEnd(v=$velocityDx, dx=$openDx)');
    // handle 在手势被接受那一帧就已建好并 attach，抬手必定在其之后。
    _drawerHandle?.settle(velocityDx: velocityDx, openDx: openDx);
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
  // 场景 A：空会话（加载快）。push 发生在手势被接受那一帧，随后 push 自己
  // 取消指针（velocity=0），settle 时 openDx 仍 ≥ 阈值 → 保持打开。
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

  // 场景 B：有历史会话（加载慢）。查询还没回来就抬手：抽屉已经在屏幕上，
  // 内容稍后补上，抬手不改变打开结果。
  testWidgets('B: slow load, lift before content arrives — drawer ends open',
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
    await tester.pumpAndSettle();

    expect(find.byKey(_drawerKey), findsOneWidget,
        reason: '查询未完成时抬手：抽屉应保持打开\n$log');
    expect(find.text('sessions: 5'), findsOneWidget,
        reason: '加载完成后内容应原地填入\n$log');
  });

  // 场景 C：先弹后填的回归锚点 —— 会话查询慢（400ms）时，抽屉在手势被接受
  // 那一帧就已经挂在屏幕上（内容为空），而不是等查询回来才出现。这是本次
  // 改动的核心：旧链路里这段时间是「手指在动、屏幕上什么都没有」。
  testWidgets('C: drawer is mounted before the session query returns',
      (tester) async {
    final log = _ReproLog();
    await _pumpHost(
      tester,
      openDelay: const Duration(milliseconds: 400),
      withMessageList: true,
      log: log,
    );

    final gesture = await _swipe(tester,
        startDx: 360, endDx: 240, dy: 400);

    // 手势进行中（约 128ms），查询必然未返回。
    expect(log.entries, isNot(contains('loaded')),
        reason: '此时会话查询应尚未完成\n$log');
    expect(find.byKey(_drawerKey), findsOneWidget,
        reason: '会话查询返回前抽屉就应已挂载（先弹后填）\n$log');
    expect(find.text('sessions: 0'), findsOneWidget,
        reason: '首帧内容为空，不应阻塞抽屉出现\n$log');

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('sessions: 5'), findsOneWidget,
        reason: '查询返回后内容原地替换，抽屉不重建\n$log');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(_drawerKey), findsOneWidget, reason: '$log');
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

  // 场景 E：越过阈值（30px）的慢速短滑。慢速 → 速度分量不足以判开，只能靠
  // 位移：push 取消指针后 settle 收到的是接受帧位移 openDx = 30 ≥ 阈值 →
  // 继续打开，「闪一下又回去」不复现（9f306a0 的回归锚点，阈值 30px）。
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

  // 场景 F：**行为变更锚点** —— 越过阈值后往回滑不再能取消打开。
  //
  // 手势被接受（越过 30px 阈值）的那一帧就 push，而 push 结尾的
  // `NavigatorState._cancelActivePointers` 会立刻取消在途指针；识别器随即
  // 以 velocity=0、openDx=接受帧位移 上报 onOpenGestureEnd 并停止跟踪，
  // 之后的回滑 move 根本到不了识别器。于是抽屉按「openDx ≥ 阈值 → 打开」
  // 收尾。
  //
  // 旧链路（先 await 查询再 push）下回滑能生效，只是因为查询慢到跨过了
  // 回滑动作；查询一快，同一条路径同样失效。真正的「跟手回滑」需要抽屉
  // 不走路由（或让路由接收手势），不在本次改动范围内。
  testWidgets('F: sliding back past the threshold no longer cancels the open',
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
    // 向右回滑 40px（慢速）：openDx 期望缩回 20 < 阈值，但指针已被取消。
    for (var i = 1; i <= 4; i++) {
      await gesture.moveTo(Offset(300 + i * 10, 400));
      await tester.pump(const Duration(milliseconds: 32));
    }
    await tester.pump(const Duration(milliseconds: 450));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(log.entries, contains('openEnd(v=0.0, dx=30.0)'),
        reason: '指针应被 push 取消，以接受帧的位移收尾（而非回滑后的位移）\n$log');
    expect(find.byKey(_drawerKey), findsOneWidget,
        reason: '回滑不再取消打开：openDx 停在阈值上 → 打开\n$log');
  });
}
