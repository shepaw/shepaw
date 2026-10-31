import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/theme/app_theme.dart';
import 'package:shepaw/widgets/contacts_tab_switcher.dart';

void main() {
  Future<ContactsTabSwitcher> pump(
    WidgetTester tester, {
    ContactsTab tab = ContactsTab.people,
  }) async {
    const widget = ContactsTabSwitcher(
      tab: ContactsTab.people,
      onChanged: _noop,
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light,
        home: Scaffold(
          body: tab == ContactsTab.people
              ? widget
              : const ContactsTabSwitcher(
                  tab: ContactsTab.devices,
                  onChanged: _noop,
                ),
        ),
      ),
    );
    return widget;
  }

  SegmentedButton<ContactsTab> _button(WidgetTester tester) =>
      tester.widget<SegmentedButton<ContactsTab>>(
        find.byType(SegmentedButton<ContactsTab>),
      );

  testWidgets('两个分段的文案都在', (tester) async {
    await pump(tester);
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ContactsTabSwitcher)),
    );
    expect(find.text(l10n.contacts_tabPeople), findsOneWidget);
    expect(find.text(l10n.contacts_tabDevices), findsOneWidget);
  });

  testWidgets('激活态用淡橘色，不是 M3 默认的 secondaryContainer', (tester) async {
    await pump(tester);
    final scheme = AppTheme.light.colorScheme;
    final style = _button(tester).style;

    // 默认取 secondaryContainer（本主题里是淡粉 accentContainer），
    // 显式改成了 primaryContainer。
    expect(scheme.secondaryContainer, isNot(scheme.primaryContainer));
    expect(
      style?.backgroundColor?.resolve({MaterialState.selected}),
      scheme.primaryContainer,
    );
    expect(
      style?.foregroundColor?.resolve({MaterialState.selected}),
      scheme.onPrimaryContainer,
    );
  });

  testWidgets('未选中的分段不高亮', (tester) async {
    await pump(tester);
    final scheme = AppTheme.light.colorScheme;
    final style = _button(tester).style;
    expect(
      style?.backgroundColor?.resolve(<MaterialState>{}),
      isNot(scheme.primaryContainer),
    );
  });

  testWidgets('选中项不显示对勾', (tester) async {
    await pump(tester);
    expect(_button(tester).showSelectedIcon, isFalse);
  });
}

void _noop(ContactsTab _) {}
