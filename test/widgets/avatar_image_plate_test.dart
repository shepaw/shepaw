import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/theme/app_theme.dart';
import 'package:shepaw/widgets/avatar_image.dart';
import 'package:shepaw/widgets/message_bubble.dart';

/// 引擎 logo 多为「透明底 + 近黑描边」（codex / cursor / kimi 等），
/// 深色模式下贴在深色页面上会完全看不见，因此头像必须自带浅色底板，
/// 且底板上方的兜底文字/图标使用深色前景。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(
    WidgetTester tester, {
    required Brightness brightness,
    required Widget avatar,
  }) {
    return tester.pumpWidget(MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
      home: Scaffold(body: Center(child: avatar)),
    ));
  }

  Color? plateColor(WidgetTester tester) {
    final finder = find.descendant(
      of: find.byType(AvatarImage),
      matching: find.byType(ColoredBox),
    );
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<ColoredBox>(finder.first).color;
  }

  testWidgets('深色模式下 emoji 头像铺深色主题底板', (tester) async {
    await pump(
      tester,
      brightness: Brightness.dark,
      avatar: const AvatarImage(
        avatar: '🤖',
        size: 32,
        borderRadius: 8,
        fallback: Text('A', style: TextStyle(fontSize: 16)),
      ),
    );

    expect(plateColor(tester), AppColors.darkAvatarPlate);
  });

  testWidgets('浅色模式下 emoji 头像铺浅色底板', (tester) async {
    await pump(
      tester,
      brightness: Brightness.light,
      avatar: const AvatarImage(
        avatar: '🤖',
        size: 32,
        borderRadius: 8,
        fallback: Text('A', style: TextStyle(fontSize: 16)),
      ),
    );

    expect(plateColor(tester), AppColors.avatarPlate);
  });

  testWidgets('showPlate=false 时不铺底板（外层容器自带底色）', (tester) async {
    await pump(
      tester,
      brightness: Brightness.dark,
      avatar: const AvatarImage(
        avatar: '🤖',
        size: 32,
        borderRadius: 8,
        showPlate: false,
        fallback: Text('A', style: TextStyle(fontSize: 16)),
      ),
    );

    expect(plateColor(tester), Colors.transparent);
  });

  testWidgets('兜底文字在底板上使用深色前景（深色模式）', (tester) async {
    await pump(
      tester,
      brightness: Brightness.dark,
      avatar: const AvatarImage(
        avatar: '',
        size: 32,
        borderRadius: 8,
        fallback: Text('A', style: TextStyle(fontSize: 16)),
      ),
    );

    final rich = tester.widget<RichText>(
      find
          .descendant(
            of: find.byType(AvatarImage),
            matching: find.byType(RichText),
          )
          .first,
    );
    expect(rich.text.style?.color, AppColors.onAvatarPlate);
    // 字号来自兜底 widget 自身，不能被底板前景色覆盖。
    expect(rich.text.style?.fontSize, 16);
  });

  testWidgets('深色模式群聊气泡里的成员头像带底板（回归：黑 logo 会看不见）',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: MessageBubble(
          isMyMessage: false,
          senderAvatar: '🤖',
          showSenderName: true,
          showAvatar: true,
          stickySenderName: true,
          message: Message(
            id: 'm1',
            content: 'hello',
            timestampMs: 0,
            from: MessageFrom(id: 'agent-a', type: 'agent', name: 'Agent A'),
            type: MessageType.text,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final plates = tester
        .widgetList<ColoredBox>(find.descendant(
          of: find.byType(MessageBubble),
          matching: find.byType(ColoredBox),
        ))
        .map((box) => box.color)
        .toList();
    expect(plates, contains(AppColors.darkAvatarPlate));
  });
}
