import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/pairing_payload.dart';
import 'package:shepaw/peer/screens/peer_manual_input_screen.dart';

/// `sha256(<32 个 0 字节>)[:8]` —— 与 `zeroKey()` 自洽。
const _fp = '66687aadf862bd77';

/// 与 `_formatFingerprint` 的分组一致（每 4 位一空格）。
const _fpGrouped = '6668 7aad f862 bd77';

Uint8List zeroKey() => Uint8List(32);

String qrWith({String? name}) => PeerPairingInfo.encode(
      localEndpoint: 'ws://192.168.1.5:18793/peer/ws',
      code: 'ABC23456',
      fingerprint: _fp,
      publicKey: zeroKey(),
      name: name,
    );

Future<void> pumpScreen(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(
      locale: Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: PeerManualInputScreen()),
    ),
  );
}

/// 输入链接并点「发起配对」——只解析，不应发起任何连接。
Future<void> submit(WidgetTester tester, String raw) async {
  await tester.enterText(find.byType(TextField), raw);
  await tester.tap(find.text('发起配对'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('合法链接 → 先出确认卡片，展示设备名与指纹，且不自动连接', (tester) async {
    await pumpScreen(tester);
    await submit(tester, qrWith(name: '客厅 Hub'));

    // 停在确认卡片上：圆形进度条（连接中）不该出现。
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('确认配对对象'), findsOneWidget);
    expect(find.text('设备名称：客厅 Hub'), findsOneWidget);
    // 安全边界文案必须与名字同时出现。
    expect(find.text('名称由对方自填，未经校验；请以指纹为准'), findsOneWidget);
    expect(find.text('指纹：$_fpGrouped'), findsOneWidget);
    expect(find.text('确认并配对'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    // 输入表单已被卡片取代。
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('旧格式链接（无 name=）→ 卡片显示「对方未提供名称」', (tester) async {
    await pumpScreen(tester);
    await submit(tester, qrWith());

    expect(find.text('确认配对对象'), findsOneWidget);
    expect(find.text('对方未提供名称'), findsOneWidget);
    // 没有名字就不该出现「名称未经校验」的提示 —— 那会指向不存在的名字。
    expect(find.text('名称由对方自填，未经校验；请以指纹为准'), findsNothing);
    // 但指纹仍然要显示：它是唯一可核对的值。
    expect(find.text('指纹：$_fpGrouped'), findsOneWidget);
  });

  testWidgets('卡片上点「取消」→ 回到输入表单', (tester) async {
    await pumpScreen(tester);
    await submit(tester, qrWith(name: '客厅 Hub'));
    expect(find.text('确认配对对象'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('确认配对对象'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('发起配对'), findsOneWidget);
  });

  testWidgets('非法内容 → 错误留在输入框，不出卡片', (tester) async {
    await pumpScreen(tester);
    await submit(tester, 'not-a-pairing-link');

    expect(find.text('确认配对对象'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('无效的配对内容'), findsOneWidget);
  });

  testWidgets('指纹被篡改的链接 → 拒绝解析，不出卡片', (tester) async {
    await pumpScreen(tester);
    // 改 pk 首位：解出的公钥变了，fp 对不上 → tryParse 必须返回 null。
    await submit(tester, qrWith(name: '客厅 Hub').replaceFirst('pk=A', 'pk=B'));

    expect(find.text('确认配对对象'), findsNothing);
    expect(find.textContaining('无效的配对内容'), findsOneWidget);
  });
}
