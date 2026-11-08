import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/screens/mobile_home_shell.dart';
import 'package:shepaw/screens/settings/settings_sections.dart';
import 'package:shepaw/widgets/desktop/mine_list_panel.dart';

/// 一级入口：工作流排在玉简和通讯录中间。
void main() {
  test('手机底栏顺序：对话 / 玉简 / 工作流 / 通讯录 / 我的', () {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(MobileHomeShell.navItems(l10n).map((item) => item.label), [
      '对话',
      '玉简',
      '工作流',
      '通讯录',
      '我的',
    ]);
  });

  testWidgets('桌面「我的」中栏不再列工作流', (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MineListPanel(
        selected: MinePage.profile,
        onSelected: (_) {},
      ),
    ));
    expect(find.text('流程库'), findsNothing);
    expect(find.text('能力'), findsOneWidget);
  });

  testWidgets('手机「我的」能力列表不再列工作流', (tester) async {
    late List<Widget> entries;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (context) {
        entries = SettingsSections.capabilities(
          context,
          l10n: AppLocalizations.of(context),
          openPage: (_) async {},
        );
        return const SizedBox();
      }),
    ));
    final labels = entries
        .whereType<ListTile>()
        .map((tile) => (tile.title as Text).data)
        .toList();
    expect(labels, isNot(contains('流程库')));
    expect(labels, isNotEmpty);
  });
}
