import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/agent_scenario_models.dart';
import 'package:shepaw/screens/model_management_screen.dart';
import 'package:shepaw/widgets/agent_model_config_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 注意：本测试不初始化 ModelRegistry（它是单例、无注入入口），所以
  /// `definitions` 为空 —— 悬空横幅刻意渲染在「registry 为空」分支之外，
  /// 正是为了这种场景也能提示「你的模型没了，而不是你没配过」。
  Future<void> pumpCard(
    WidgetTester tester, {
    String? mainModelId,
    String? danglingModelName,
    ValueChanged<String?>? onMainModelChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AgentModelConfigCard(
            mainModelId: mainModelId,
            onMainModelChanged: onMainModelChanged ?? (_) {},
            scenarioModels: const AgentScenarioModels(),
            onScenarioModelsChanged: (_) {},
            showRequiredBadge: true,
            danglingModelName: danglingModelName,
          ),
        ),
      ),
    );
  }

  testWidgets('悬空模型显示提示并带上原始 id', (tester) async {
    await pumpCard(tester, danglingModelName: 'def-1234');

    expect(find.text('原主模型（def-1234）已不存在，请重新选择'), findsOneWidget);
    expect(find.text('前往模型管理'), findsOneWidget);
  });

  testWidgets('悬空时不重复弹「请选择模型」', (tester) async {
    await pumpCard(tester, danglingModelName: 'def-1234');

    expect(find.text('请选择模型'), findsNothing);
  });

  testWidgets('未悬空时不显示悬空提示', (tester) async {
    await pumpCard(tester);

    expect(find.textContaining('已不存在'), findsNothing);
    // registry 为空时没有「请选择模型」引导（那条只在有候选模型时出现），
    // 取而代之的是空态提示 + 入口按钮。
    expect(find.text('未配置模型，请先在设置中添加模型'), findsOneWidget);
    expect(find.text('前往模型管理'), findsOneWidget);
  });

  testWidgets('横幅上的按钮直达模型管理页', (tester) async {
    await pumpCard(tester, danglingModelName: 'def-1234');

    await tester.tap(find.text('前往模型管理'));
    await tester.pumpAndSettle();

    expect(find.byType(ModelManagementScreen), findsOneWidget);
  });
}
