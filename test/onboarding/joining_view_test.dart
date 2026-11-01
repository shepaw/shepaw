import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/onboarding/joining_view.dart';
import 'package:shepaw/peer/models/paired_peer.dart';
import 'package:shepaw/peer/models/pairing_payload.dart';

PairedPeer peer([String id = 'peer-1']) {
  return PairedPeer(
    id: id,
    deviceName: 'EDENZOU-MB2',
    deviceId: 'dev',
    publicKey: Uint8List.fromList(List<int>.filled(32, 7)),
    fingerprint: 'fp-$id',
    localEndpoint: 'ws://192.168.1.5:18793/peer/ws',
    pairedAt: 1759276800000,
  );
}

PeerPairingInfo info() {
  return PeerPairingInfo(
    localEndpoint: 'ws://192.168.1.5:18793/peer/ws',
    channelEndpoint: null,
    code: 'ABCD2345',
    fingerprint: 'fp-local',
    publicKey: Uint8List.fromList(List<int>.filled(32, 3)),
    name: 'EDENZOU-MB2',
  );
}

class FakeSteps implements JoiningSteps {
  FakeSteps({
    this.pairError,
    this.connectError,
    this.redialSucceeds = true,
    this.hostPasswordSet = true,
  });

  final Object? pairError;
  final Object? connectError;
  final bool redialSucceeds;
  final bool hostPasswordSet;

  /// 给配对这步把住，好在「加入中」的时候点取消。
  Completer<void>? pairGate;

  int pairs = 0;
  int connects = 0;
  int probes = 0;
  final List<bool> redials = [];

  @override
  Future<PairedPeer> pair(PeerPairingInfo info) async {
    pairs++;
    final gate = pairGate;
    if (gate != null) await gate.future;
    final error = pairError;
    if (error != null) throw error;
    return peer();
  }

  @override
  Future<void> connect(
    PairedPeer peer, {
    required bool redial,
  }) async {
    connects++;
    redials.add(redial);
    if (!redial) {
      final error = connectError;
      if (error != null) throw error;
      return;
    }
    if (!redialSucceeds) throw StateError('还是连不上');
  }

  @override
  Future<bool> passwordSet(String hostPeerId) async {
    probes++;
    return hostPasswordSet;
  }
}

/// 页面里有个一直重复的脉冲动画，pumpAndSettle 永远等不到静止。
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget app(JoiningView view) {
  return MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: view,
  );
}

void main() {
  testWidgets('主机已经设过密码就去解锁', (tester) async {
    final steps = FakeSteps();
    JoinOutcome? outcome;
    PairedPeer? got;
    await tester.pumpWidget(app(JoiningView(
      info: info(),
      steps: steps,
      onCancel: () {},
      onDone: (peer, result) {
        got = peer;
        outcome = result;
      },
    )));
    await settle(tester);
    expect(outcome, JoinOutcome.unlock);
    expect(got?.id, 'peer-1');
    expect(steps.probes, 1);
  });

  testWidgets('主机还没设密码就等电脑', (tester) async {
    final steps = FakeSteps(hostPasswordSet: false);
    JoinOutcome? outcome;
    await tester.pumpWidget(app(JoiningView(
      info: info(),
      steps: steps,
      onCancel: () {},
      onDone: (_, result) => outcome = result,
    )));
    await settle(tester);
    expect(outcome, JoinOutcome.waitHost);
  });

  testWidgets('第一次连不上就断开重试一次', (tester) async {
    final steps = FakeSteps(connectError: TimeoutException('连不上'));
    JoinOutcome? outcome;
    await tester.pumpWidget(app(JoiningView(
      info: info(),
      steps: steps,
      onCancel: () {},
      onDone: (_, result) => outcome = result,
    )));
    await settle(tester);
    expect(steps.redials, [false, true]);
    expect(outcome, JoinOutcome.unlock);
  });

  testWidgets('重试也连不上就算离线', (tester) async {
    final steps = FakeSteps(
      connectError: TimeoutException('连不上'),
      redialSucceeds: false,
    );
    JoinOutcome? outcome;
    await tester.pumpWidget(app(JoiningView(
      info: info(),
      steps: steps,
      onCancel: () {},
      onDone: (_, result) => outcome = result,
    )));
    await settle(tester);
    expect(outcome, JoinOutcome.offline);
    // 连不上就不再问主机有没有密码。
    expect(steps.probes, 0);
  });

  testWidgets('配对失败也算离线，而且不弹原始错误', (tester) async {
    final steps = FakeSteps(pairError: StateError('Boom'));
    JoinOutcome? outcome;
    await tester.pumpWidget(app(JoiningView(
      info: info(),
      steps: steps,
      onCancel: () {},
      onDone: (peer, result) {
        outcome = result;
        expect(peer, isNull);
      },
    )));
    await settle(tester);
    expect(outcome, JoinOutcome.offline);
    expect(find.textContaining('Boom'), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);
  });

  testWidgets('取消之后不再往下走', (tester) async {
    final steps = FakeSteps()..pairGate = Completer<void>();
    var cancelled = false;
    var done = false;
    await tester.pumpWidget(app(JoiningView(
      info: info(),
      steps: steps,
      onCancel: () => cancelled = true,
      onDone: (_, __) => done = true,
    )));
    await tester.pump();
    await tester.tap(find.byType(TextButton).first);
    await tester.pump();
    expect(cancelled, isTrue);
    // 配对这会儿才完成：已经取消过了，不该再往下走。
    steps.pairGate!.complete();
    await settle(tester);
    expect(done, isFalse);
    expect(steps.probes, 0);
  });
}
