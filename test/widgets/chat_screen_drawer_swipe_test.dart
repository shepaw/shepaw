import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/screens/chat_screen.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

/// 真机链路复现：真实 ChatScreen + 真实控制器 + 真实（ffi 内存）数据库。
///
/// 对比两种会话：
/// - 有历史消息的会话（进入后消息列表已加载）
/// - 新建未聊天的会话（空状态）
/// 左滑打开抽屉，观察抽屉最终是否打开（不闪退）。
///
/// ffi 数据库走真实异步，testWidgets 的 FakeAsync 下无法完成，
/// 因此所有涉及 DB 的操作（建会话、等 init 完成）都包在 runAsync 里。
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await StorageTestHarness.init();
    setupServiceLocator();
  });

  /// 手机尺寸：800x600 的默认测试表面会被 isDesktopLayout 判定为桌面布局，
  /// 直接禁用抽屉滑动识别（enabled: !isDesktopLayout），复现链根本不存在。
  void usePhoneSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  Future<void> createChannel(
    LocalDatabaseService db, {
    required String channelId,
    required String name,
    required String agentId,
  }) async {
    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: name,
        type: 'dm',
        memberIds: ['user', agentId],
        isPrivate: true,
      ),
      'user',
    );
  }

  Future<void> seedHistory(
    LocalDatabaseService db, {
    required String channelId,
    required String agentId,
    int messageCount = 30,
  }) async {
    // 同文件内多个用例共享同一个 ffi 数据库文件，消息 id 必须带用例前缀，
    // 否则跨用例重复（UNIQUE constraint failed: messages.id）。
    for (var i = 0; i < messageCount; i++) {
      await db.createMessage(
        id: '$channelId-msg-$i',
        channelId: channelId,
        senderId: i.isEven ? 'user' : agentId,
        senderType: i.isEven ? 'user' : 'agent',
        senderName: i.isEven ? 'User' : 'Agent',
        content: '历史消息 $i：这是一条用于复现侧滑闪烁问题的聊天记录。',
        metadata: {'status': 'completed'},
      );
    }
  }

  Future<void> pumpChatScreen(
    WidgetTester tester, {
    required String agentId,
    required String channelId,
  }) async {
    // 消息加载走真实 DB（ffi isolate），必须在 runAsync 里等它完成。
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: ChatScreen(
            agentId: agentId,
            agentName: 'Agent',
            channelId: channelId,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 从 (startDx, dy) 向左拖 [distance]，完成一次左滑。
  ///
  /// 关键：会话加载（真实 ffi DB）在手指仍在屏幕上的时候完成 ——
  /// push 抽屉路由发生在手势中途，`Navigator._cancelActivePointers` 会取消
  /// 在途指针（velocity 归零），这正是真机上「闪一下又回去」的触发时机。
  /// 因此整个手势过程都包在 runAsync 里，让真实 I/O 能在悬停期间完成。
  Future<void> swipeLeftWithMidGesturePush(
    WidgetTester tester, {
    required double startDx,
    required double distance,
    required double dy,
    Duration midGestureDelay = const Duration(milliseconds: 40),
  }) async {
    await tester.runAsync(() async {
      final gesture = await tester.startGesture(Offset(startDx, dy));
      // 前 4 步：识别器接受（8px）并开始异步加载会话。
      for (var i = 1; i <= 4; i++) {
        await gesture.moveTo(Offset(startDx - distance * i / 10, dy));
        await tester.pump(const Duration(milliseconds: 16));
      }
      // 悬停：真实 DB 查询在此期间完成 → push 发生（手指仍在屏幕上）。
      await Future<void>.delayed(midGestureDelay);
      // 后 6 步：继续滑动到目标距离再抬手。
      for (var i = 5; i <= 10; i++) {
        await gesture.moveTo(Offset(startDx - distance * i / 10, dy));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    });
  }

  bool drawerVisible(WidgetTester tester) {
    // ChatMoreDrawer 的搜索框 hint 文案（以图标兜底）。
    return find.byIcon(Icons.search_outlined).evaluate().isNotEmpty ||
        find.byIcon(Icons.search).evaluate().isNotEmpty;
  }

  testWidgets('history session: left-swipe opens drawer without flash',
      (tester) async {
    usePhoneSurface(tester);
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-$suffix';
    final channelId = 'dm_user_$agentId-$suffix';
    await tester.runAsync(() async {
      await createChannel(db, channelId: channelId, name: 'History', agentId: agentId);
      await seedHistory(db, channelId: channelId, agentId: agentId);
    });

    await pumpChatScreen(tester, agentId: agentId, channelId: channelId);

    // 历史消息应已渲染。
    expect(find.textContaining('历史消息'), findsWidgets);

    await swipeLeftWithMidGesturePush(tester,
        startDx: 360, distance: 150, dy: 400);

    expect(drawerVisible(tester), isTrue,
        reason: '有历史记录的会话：左滑后抽屉应保持打开，而不是闪一下退回');
  });

  testWidgets('fresh session: left-swipe opens drawer', (tester) async {
    usePhoneSurface(tester);
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-fresh-$suffix';
    final channelId = 'dm_user_$agentId-$suffix';
    await tester.runAsync(() async {
      await createChannel(db, channelId: channelId, name: 'Fresh', agentId: agentId);
    });

    await pumpChatScreen(tester, agentId: agentId, channelId: channelId);

    await swipeLeftWithMidGesturePush(tester,
        startDx: 360, distance: 150, dy: 400);

    expect(drawerVisible(tester), isTrue, reason: '新会话：左滑后抽屉应打开');
  });

  testWidgets('right-edge swipe (system back zone) does not open drawer',
      (tester) async {
    usePhoneSurface(tester);
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-edge-$suffix';
    final channelId = 'dm_user_$agentId-$suffix';
    await tester.runAsync(() async {
      await createChannel(db, channelId: channelId, name: 'Edge', agentId: agentId);
      await seedHistory(db, channelId: channelId, agentId: agentId);
    });

    await pumpChatScreen(tester, agentId: agentId, channelId: channelId);

    // Android 手势返回 = 右边缘左滑，应让给系统返回。390 宽表面、测试环境
    // 无 systemGestureInsets（0 → 兜底 20px）：区带为 [370, 390)。
    await swipeLeftWithMidGesturePush(tester,
        startDx: 385, distance: 100, dy: 400);

    expect(drawerVisible(tester), isFalse,
        reason: '右边缘系统手势区内的左滑应让给系统返回，不打开抽屉');
  });
}
