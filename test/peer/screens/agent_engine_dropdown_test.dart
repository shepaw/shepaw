import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/screens/engine_setup_screen.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

PeerEngineEntry _engine({
  required String id,
  required String name,
  required bool available,
  String unavailableReason = '',
}) {
  return PeerEngineEntry(
    id: id,
    name: name,
    available: available,
    unavailableReason: unavailableReason,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required List<PeerEngineEntry> engines,
  required String? selectedId,
  required ValueChanged<PeerEngineEntry> onSelected,
  required ValueChanged<PeerEngineEntry> onUnavailable,
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            return AgentEngineDropdown(
              engines: engines,
              selectedId: selectedId,
              enabled: true,
              onSelected: (engine) {
                setState(() => selectedId = engine.id);
                onSelected(engine);
              },
              onUnavailable: onUnavailable,
            );
          },
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('已选引擎显示绿色「可用」，下拉可选另一台可用引擎', (tester) async {
    final engines = [
      _engine(id: 'alpha', name: 'Alpha', available: true),
      _engine(id: 'gamma', name: 'Gamma', available: true),
    ];
    String? selected = 'alpha';
    PeerEngineEntry? picked;
    await _pump(
      tester,
      engines: engines,
      selectedId: selected,
      onSelected: (engine) => picked = engine,
      onUnavailable: (_) {},
    );

    final chip = tester.widget<Text>(find.text('可用'));
    expect(chip.style?.color, const Color(0xFF2E7D32));

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gamma').last);
    await tester.pumpAndSettle();

    expect(picked?.id, 'gamma');
    expect(find.text('Gamma'), findsOneWidget);
  });

  testWidgets('点不可用引擎打开配置，不改当前选择', (tester) async {
    final engines = [
      _engine(id: 'alpha', name: 'Alpha', available: true),
      _engine(
        id: 'beta',
        name: 'Beta',
        available: false,
        unavailableReason: '主机上找不到命令',
      ),
    ];
    PeerEngineEntry? picked;
    PeerEngineEntry? configured;
    await _pump(
      tester,
      engines: engines,
      selectedId: 'alpha',
      onSelected: (engine) => picked = engine,
      onUnavailable: (engine) => configured = engine,
    );

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('主机上找不到命令'), findsOneWidget);
    expect(find.text('去配置'), findsOneWidget);

    final unavailable = tester.widget<Text>(find.text('不可用'));
    expect(unavailable.style?.color, isNot(const Color(0xFF2E7D32)));

    await tester.tap(find.text('Beta').last);
    await tester.pumpAndSettle();

    expect(configured?.id, 'beta');
    expect(picked, isNull);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
  });

  testWidgets('深色模式下「可用」用更亮的绿', (tester) async {
    await _pump(
      tester,
      engines: [_engine(id: 'alpha', name: 'Alpha', available: true)],
      selectedId: 'alpha',
      onSelected: (_) {},
      onUnavailable: (_) {},
      theme: ThemeData(brightness: Brightness.dark),
    );
    final chip = tester.widget<Text>(find.text('可用'));
    expect(chip.style?.color, const Color(0xFF81C784));
  });
}
