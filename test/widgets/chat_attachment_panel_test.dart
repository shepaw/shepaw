import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/screens/chat_screen.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

/// 移动端 WeChat 风格「＋」面板：
/// - 「＋」图标移到输入框左边，独立表情按钮移除
/// - 点击「＋」弹出图标网格：表情 / 相册 / 相机 / 文件 / 储物袋 / 指令
/// - 点「表情」切换到表情面板；再点「＋」收起到键盘态
///
/// 注意：不依赖 pumpAndSettle —— 聊天页可能存在持续动画（如加载指示器），
/// pumpAndSettle 会空转超时。统一用固定时长的 pump 推进帧。
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await StorageTestHarness.init();
    setupServiceLocator();
  });

  void usePhoneSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  Future<void> settleFrames(WidgetTester tester,
      [int frames = 6, Duration step = const Duration(milliseconds: 50)]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(step);
    }
  }

  Future<void> pumpChatScreen(
    WidgetTester tester, {
    required String agentId,
    required String channelId,
  }) async {
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

  /// 建会话走真实 ffi DB，必须在 runAsync 里等异步完成（同 drawer 测试）。
  Future<(String, String)> createFreshChannel(WidgetTester tester) async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-panel-$suffix';
    final channelId = 'dm_user_$agentId-$suffix';
    final db = LocalDatabaseService();
    await tester.runAsync(() async {
      await db.createChannel(
        Channel.withMemberIds(
          id: channelId,
          name: 'Panel',
          type: 'dm',
          memberIds: ['user', agentId],
          isPrivate: true,
        ),
        'user',
      );
    });
    return (agentId, channelId);
  }

  testWidgets('mobile input bar: add icon left of text field, no standalone emoji button',
      (tester) async {
    usePhoneSurface(tester);
    final (agentId, channelId) = await createFreshChannel(tester);
    await pumpChatScreen(tester, agentId: agentId, channelId: channelId);

    // 独立表情按钮已从工具栏移除。
    expect(find.byIcon(Icons.emoji_emotions_outlined), findsNothing);

    final addIcon = find.byIcon(Icons.add_circle_outline);
    expect(addIcon, findsOneWidget, reason: '「＋」按钮应存在');

    // 「＋」在输入框左边。
    final addRect = tester.getRect(addIcon);
    final fieldRect = tester.getRect(find.byType(TextField).first);
    expect(addRect.center.dx, lessThan(fieldRect.center.dx),
        reason: '「＋」应位于输入框左侧');
  });

  testWidgets('tapping add opens WeChat-style grid with 6 actions', (tester) async {
    usePhoneSurface(tester);
    final (agentId, channelId) = await createFreshChannel(tester);
    await pumpChatScreen(tester, agentId: agentId, channelId: channelId);

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await settleFrames(tester);

    // 图标网格面板出现，含 6 个动作。
    final grid = find.byKey(const Key('chat_attachment_panel'));
    expect(grid, findsOneWidget);
    for (final label in ['表情', '相册', '相机', '文件', '储物袋', '指令']) {
      expect(
        find.descendant(of: grid, matching: find.text(label)),
        findsOneWidget,
        reason: '面板应包含「$label」',
      );
    }

    // 再次点「＋」（此时为键盘图标）收起面板。
    await tester.tap(find.byIcon(Icons.keyboard_alt_outlined));
    await settleFrames(tester);
    expect(find.byKey(const Key('chat_attachment_panel')), findsNothing);
  });

  testWidgets('tapping emoji action switches to emoji picker', (tester) async {
    usePhoneSurface(tester);
    final (agentId, channelId) = await createFreshChannel(tester);
    await pumpChatScreen(tester, agentId: agentId, channelId: channelId);

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await settleFrames(tester);

    // 点面板里的「表情」。
    final grid = find.byKey(const Key('chat_attachment_panel'));
    await tester.tap(find.descendant(of: grid, matching: find.text('表情')));
    await settleFrames(tester);

    // 附件网格消失，表情面板出现。
    expect(find.byKey(const Key('chat_attachment_panel')), findsNothing);
    expect(find.byType(EmojiPicker), findsOneWidget);
  });
}
