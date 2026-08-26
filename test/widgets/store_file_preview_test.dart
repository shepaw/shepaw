import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/widgets/store_file_preview.dart';

/// store 文件预览页的 app bar 动作。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPage(WidgetTester tester, String? storeUri) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: StoreFilePreviewPage(
          fileName: 'snake-game.html',
          storeUri: storeUri,
          body: const Text('preview body'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('有 storeUri 时显示「在储物袋中显示」按钮', (tester) async {
    await pumpPage(
      tester,
      'store://workspaces/aaaaaaaaaaaaaaaa/group_x/snake-game.html',
    );
    expect(find.byIcon(Icons.folder_open_outlined), findsOneWidget);
    expect(find.byIcon(Icons.link), findsOneWidget);
    expect(find.byIcon(Icons.ios_share_outlined), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);
  });

  testWidgets('无 storeUri 时不显示储物袋跳转按钮', (tester) async {
    await pumpPage(tester, null);
    expect(find.byIcon(Icons.folder_open_outlined), findsNothing);
    // 无 storeUri 时路径/分享也不出现，仅保留「用系统应用打开」。
    expect(find.byIcon(Icons.link), findsNothing);
    expect(find.byIcon(Icons.ios_share_outlined), findsNothing);
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);
  });
}
