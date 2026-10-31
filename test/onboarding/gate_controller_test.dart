import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/onboarding/credential_restore.dart';
import 'package:shepaw/onboarding/gate_controller.dart';
import 'package:shepaw/onboarding/gate_errors.dart';
import 'package:shepaw/onboarding/widgets/gate_widgets.dart';
import 'package:shepaw/peer/models/paired_peer.dart';
import 'package:shepaw/storage/pouch_catalog.dart';
import 'package:shepaw/storage/pouch_login_client.dart';
import 'package:shepaw/storage/pouch_session.dart';

const study = PouchDescriptor(id: 'a', name: 'Eden 的储物袋', rootPath: '');

PairedPeer peer(String id) {
  return PairedPeer(
    id: id,
    deviceName: 'EDENZOU-MB2',
    deviceId: 'dev-$id',
    publicKey: Uint8List.fromList(List<int>.filled(32, 7)),
    fingerprint: 'fp-$id',
    localEndpoint: 'ws://127.0.0.1:18794/peer/ws',
    pairedAt: 1759276800000,
  );
}

PouchSession session({String hostPeerId = 'peer-1'}) {
  return PouchSession(
    hubUrl: 'ws://127.0.0.1:18794/peer/ws',
    pouchId: 'a',
    pouchName: 'Eden 的储物袋',
    hostPeerId: hostPeerId,
    token: '',
    sessionId: '',
    expiresAtMs: 0,
  );
}

class FakeDeps {
  FakeDeps({
    this.current,
    this.pouches = const [study],
    this.loginError,
    this.connectError,
    this.listError,
    this.restoreResult = RestoreResult.none,
  });

  final PouchSession? current;
  final List<PouchDescriptor> pouches;
  final Object? loginError;
  final Object? connectError;
  final Object? listError;
  final RestoreResult restoreResult;

  final List<PouchSession> persisted = [];
  final List<PouchSession> installed = [];
  final StreamController<Set<String>> connected =
      StreamController<Set<String>>.broadcast();
  int loginCalls = 0;
  int connectCalls = 0;
  int restoreCalls = 0;
  String? lastPassword;

  GateDeps build() {
    return GateDeps(
      readSession: () async => current,
      lookupPeer: (id) async => peer(id),
      listPouches: (_) async {
        final error = listError;
        if (error != null) throw error;
        return pouches;
      },
      login: ({required hostPeerId, required pouchId, required password}) async {
        loginCalls++;
        lastPassword = password;
        final error = loginError;
        if (error != null) throw error;
        return const PouchLoginGrant(
          token: 't',
          sessionId: 's',
          expiresAtMs: 9999999999999,
        );
      },
      persist: (next) async => persisted.add(next),
      installChannel: installed.add,
      connect: (p, {required bool redial}) async {
        connectCalls++;
        final error = connectError;
        if (error != null) throw error;
      },
      credentials: null,
      connectedIds: () => connected.stream,
      restore: (hostPeerId) async {
        restoreCalls++;
        return restoreResult;
      },
    );
  }
}

GateController build(FakeDeps fake) => GateController(deps: fake.build());

void main() {
  testWidgets('进页面就推出袋子，主机在线', (tester) async {
    final fake = FakeDeps(current: session());
    final gate = build(fake);
    await gate.load('peer-1');
    await tester.pump();
    expect(gate.pouch?.id, 'a');
    expect(gate.pouchName, 'Eden 的储物袋');
    expect(gate.reach, HostReachability.online);
    expect(gate.error, isNull);
    gate.dispose();
  });

  testWidgets('本机没记住袋子时问主机', (tester) async {
    final fake = FakeDeps();
    final gate = build(fake);
    await gate.load('peer-1');
    await tester.pump();
    expect(gate.pouch?.id, 'a');
    gate.dispose();
  });

  testWidgets('问主机失败不清掉已经推出来的袋子', (tester) async {
    final fake = FakeDeps(
      current: session(),
      listError: TimeoutException('主机没回'),
    );
    final gate = build(fake);
    await gate.load('peer-1');
    await tester.pump();
    // 袋子还在，主机状态转成离线；错误不在错误位显示，交给离线卡片。
    expect(gate.pouch?.id, 'a');
    expect(gate.reach, HostReachability.offline);
    expect(gate.error, isNull);
    gate.dispose();
  });

  testWidgets('连不上主机时状态是离线', (tester) async {
    final fake = FakeDeps(
      current: session(),
      connectError: TimeoutException('连不上'),
      listError: TimeoutException('连不上'),
    );
    final gate = build(fake);
    await gate.load('peer-1');
    await tester.pump();
    expect(gate.reach, HostReachability.offline);
    gate.dispose();
  });

  testWidgets('密码正确：存会话、装通道', (tester) async {
    final fake = FakeDeps(current: session());
    final gate = build(fake);
    await gate.load('peer-1');
    await tester.pump();
    expect(await gate.submitPassword('secret1'), isTrue);
    expect(fake.lastPassword, 'secret1');
    expect(fake.persisted.single.token, 't');
    expect(fake.installed.single.token, 't');
    expect(gate.error, isNull);
    gate.dispose();
  });

  testWidgets('密码不对：不写会话，抖动一次', (tester) async {
    final fake = FakeDeps(
      current: session(),
      loginError: const PouchPasswordRequired('密码不对', code: 'wrong_password'),
    );
    final gate = build(fake);
    await gate.load('peer-1');
    await tester.pump();
    final before = gate.shakeKey;
    expect(await gate.submitPassword('nope'), isFalse);
    expect(gate.error?.kind, GateErrorKind.wrongPassword);
    expect(gate.shakeKey, before + 1);
    expect(fake.persisted, isEmpty);
    gate.dispose();
  });

  testWidgets('锁定时主按钮走倒计时，到点自动恢复', (tester) async {
    final fake = FakeDeps(
      current: session(),
      loginError: const PouchPasswordRequired(
        '试错太多次',
        code: 'locked',
        retryAfter: Duration(milliseconds: 120),
      ),
    );
    final gate = build(fake);
    await gate.load('peer-1');
    await tester.pump();
    expect(await gate.submitPassword('nope'), isFalse);
    expect(gate.locked, isTrue);
    // 锁定期间直接拒绝，不再打主机。
    expect(await gate.submitPassword('nope'), isFalse);
    expect(fake.loginCalls, 1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(gate.locked, isFalse);
    gate.dispose();
  });

  testWidgets('主机连上后静默续期成功就自己进主页', (tester) async {
    final fake = FakeDeps(current: session(), restoreResult: RestoreResult.restored);
    final gate = build(fake);
    await gate.load('peer-1');
    await tester.pump();
    fake.connected.add({'peer-1'});
    await tester.pump();
    expect(gate.reach, HostReachability.online);
    expect(gate.restored, isTrue);
    gate.dispose();
  });

  testWidgets('主机掉线时状态跟着变', (tester) async {
    final fake = FakeDeps(current: session());
    final gate = build(fake);
    await gate.load('peer-1');
    await tester.pump();
    expect(gate.reach, HostReachability.online);
    fake.connected.add(<String>{});
    await tester.pump();
    expect(gate.reach, HostReachability.offline);
    gate.dispose();
  });

  testWidgets('主机上连一只袋子都没有', (tester) async {
    final fake = FakeDeps(pouches: const []);
    final gate = build(fake);
    await gate.load('peer-1');
    await tester.pump();
    expect(gate.noPouch, isTrue);
    expect(await gate.submitPassword('secret1'), isFalse);
    gate.dispose();
  });
}
