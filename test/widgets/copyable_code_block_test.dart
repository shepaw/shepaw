import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/copyable_code_block.dart';
import 'package:shepaw/widgets/message_bubble.dart';

/// 代码块复制按钮的锚点测试。
///
/// 最关键的是第 3 组：flutter_markdown 0.6.x 对 `pre` 只走
/// `MarkdownBuilder.visitText`（不查 `builders` 的 block 分支、不调用
/// `visitElementAfterWithContext`）。若挂载点写错，按钮会静默不显示；
/// 若 `visitText` 返回 null，整段代码文本会消失。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Message textMessage(String id, String content) {
    return Message(
      id: id,
      content: content,
      timestampMs: 0,
      from: MessageFrom(id: 'a-1', type: 'agent', name: 'Agent'),
      type: MessageType.text,
    );
  }

  Future<void> pumpBubble(
    WidgetTester tester,
    String content, {
    bool isMyMessage = false,
    double width = 400,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: MessageBubble(
              message: textMessage('m1', content),
              isMyMessage: isMyMessage,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('codeBlockClipboardText', () {
    test('只去掉一个结尾换行', () {
      expect(codeBlockClipboardText('code\n'), 'code');
      expect(codeBlockClipboardText('code'), 'code');
      expect(codeBlockClipboardText('a\n\n'), 'a\n', reason: '尾部的空行有意义');
      expect(codeBlockClipboardText('a\r\n'), 'a');
      expect(codeBlockClipboardText('a\r'), 'a');
      expect(codeBlockClipboardText(''), '');
      expect(codeBlockClipboardText('\n'), '');
      expect(codeBlockClipboardText('a\nb\n'), 'a\nb', reason: '中间换行保留');
    });
  });

  group('复制交互', () {
    late List<MethodCall> platformCalls;

    setUp(() {
      platformCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    Future<void> flushToastTimers(WidgetTester tester) async {
      // toast 自带 3s 后自动消失的 timer + 1.6s 的按钮回弹 timer。
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    }

    testWidgets('点击按钮把纯代码写进剪贴板并弹出提示', (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: CopyableCodeBlock(
                code: 'echo hi\nrm -rf /tmp/x',
                textStyle: TextStyle(color: Colors.black),
                padding: EdgeInsets.all(10),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(l10n.chat_copiedToClipboard), findsNothing);
      await tester.tap(find.byIcon(Icons.copy_rounded));
      await tester.pump();

      final clipboardCalls = platformCalls
          .where((call) => call.method == 'Clipboard.setData')
          .toList();
      expect(clipboardCalls, hasLength(1));
      expect(
        (clipboardCalls.single.arguments as Map)['text'],
        'echo hi\nrm -rf /tmp/x',
      );
      // 提示出现，且不夹带散文。
      expect(find.text(l10n.chat_copiedToClipboard), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget, reason: '顶部绿色 toast');

      await flushToastTimers(tester);
    });

    testWidgets('点击后按钮短暂变成对勾', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: CopyableCodeBlock(
                code: 'x',
                textStyle: TextStyle(color: Colors.black),
                padding: EdgeInsets.all(10),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.copy_rounded));
      await tester.pump();
      expect(find.byIcon(Icons.check), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1700));
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);

      await flushToastTimers(tester);
    });
  });

  group('Markdown 路由', () {
    testWidgets('只给 fenced block 加按钮，inline code 不加', (tester) async {
      await pumpBubble(
        tester,
        '这里有一段 inline `x = 1` 代码，下面是块：\n\n'
            '```dart\nvoid main() {\n  foo();\n}\n```\n',
      );

      expect(
        find.byType(CopyableCodeBlock),
        findsOneWidget,
        reason: '只有 fenced block 挂按钮，inline code 不能有',
      );
      // 防「visitText 返回 null 导致整段代码文本消失」这个失败模式。
      expect(
        find.textContaining('foo();', findRichText: true),
        findsOneWidget,
      );
      // 代码块外的散文仍在。
      expect(find.textContaining('下面是块', findRichText: true), findsOneWidget);
    });

    testWidgets('一条消息里的多个代码块各有一个按钮', (tester) async {
      await pumpBubble(
        tester,
        '```\nfirst();\n```\n\n中间散文\n\n```sh\nsecond();\n```\n',
      );

      expect(find.byType(CopyableCodeBlock), findsNWidgets(2));
      expect(find.textContaining('first();', findRichText: true), findsOneWidget);
      expect(find.textContaining('second();', findRichText: true), findsOneWidget);
    });

    testWidgets('空代码块仍有按钮（不会被裁掉）', (tester) async {
      await pumpBubble(tester, '```\n```\n');

      expect(find.byType(CopyableCodeBlock), findsOneWidget);
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
      final size = tester.getSize(find.byType(CopyableCodeBlock));
      expect(
        size.height,
        greaterThanOrEqualTo(CopyableCodeBlock.buttonGutter),
        reason: 'ConstrainedBox 保证 Positioned 按钮不被顶出下边界',
      );
    });

    testWidgets('窄气泡里不溢出（gutter 挤压后仍能横向滚）', (tester) async {
      // 32px gutter 是这次改动引入的横向成本，窄气泡是最坏情况。
      await pumpBubble(
        tester,
        '```\nsome_long_command --flag value\n```\n',
        width: 160,
      );

      final copyable = find.byType(CopyableCodeBlock);
      expect(copyable, findsOneWidget);
      expect(tester.takeException(), isNull, reason: '不应有 overflow');
      expect(
        tester.getSize(copyable).width,
        lessThanOrEqualTo(160.0),
      );
      // 按钮必须仍在可视范围内。
      final button = tester.getRect(find.byIcon(Icons.copy_rounded));
      expect(button.right, lessThanOrEqualTo(160.0));
      expect(button.left, greaterThan(0.0));
    });

    testWidgets('按钮颜色跟随代码字形（深色气泡用白色）', (tester) async {
      await pumpBubble(tester, '```\nfoo();\n```\n', isMyMessage: true);

      final icon = tester.widget<Icon>(find.byIcon(Icons.copy_rounded));
      expect(
        icon.color,
        Colors.white,
        reason: '必须取 styleSheet.code.color（styles["pre"] 是段落样式，不是 monospace）',
      );
    });

    testWidgets('浅色气泡按钮用 onSurface', (tester) async {
      await pumpBubble(tester, '```\nfoo();\n```\n', isMyMessage: false);

      final icon = tester.widget<Icon>(find.byIcon(Icons.copy_rounded));
      expect(icon.color, isNot(Colors.white));
      expect(icon.color, isNotNull);
    });

    testWidgets('鼠标悬停时按钮变实', (tester) async {
      await pumpBubble(tester, '```\nfoo();\n```\n');

      AnimatedOpacity opacity() => tester.widget<AnimatedOpacity>(
            find.ancestor(
              of: find.byIcon(Icons.copy_rounded),
              matching: find.byType(AnimatedOpacity),
            ),
          );
      expect(opacity().opacity, lessThan(1.0), reason: '常驻半透明，触屏可见');

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tester.pump();
      await mouse.moveTo(tester.getCenter(find.byIcon(Icons.copy_rounded)));
      await tester.pumpAndSettle();

      expect(opacity().opacity, 1.0);
    });

    testWidgets('流式未闭合围栏也能渲染（按钮在，代码在）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: MessageBubble(
                message: textMessage('m2', '```sh\npartial_command --fl'),
                isMyMessage: false,
                isStreaming: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CopyableCodeBlock), findsOneWidget);
      expect(
        find.textContaining('partial_command', findRichText: true),
        findsOneWidget,
      );
    });
  });
}
