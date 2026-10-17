import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/widgets/chat/chat_more_drawer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpDrawer(
    WidgetTester tester, {
    required List<String> queries,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: ChatMoreDrawer(
            header: const Text('header'),
            searchHint: '搜索会话',
            bodyBuilder: (context, query) {
              queries.add(query);
              return Text('body:$query', key: const Key('search-body'));
            },
          ),
        ),
      ),
    );
  }

  testWidgets('连续输入只在停手后提交一次查询', (tester) async {
    final queries = <String>[];
    await pumpDrawer(tester, queries: queries);
    expect(queries, ['']);

    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'ab');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump(const Duration(milliseconds: 299));

    expect(queries.where((q) => q.isNotEmpty), isEmpty);

    await tester.pump(const Duration(milliseconds: 1));

    expect(queries.where((q) => q.isNotEmpty).toList(), ['abc']);
    expect(find.text('body:abc'), findsOneWidget);
  });

  testWidgets('清空立刻回到完整列表，不等待防抖', (tester) async {
    final queries = <String>[];
    await pumpDrawer(tester, queries: queries);

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('body:abc'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump();

    expect(queries.last, '');
    expect(find.text('body:'), findsOneWidget);
  });
}
