import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/storage/pouch_credential_store.dart';
import 'package:shepaw/storage/pouch_login_client.dart';
import 'package:shepaw/storage/pouch_login_keeper.dart';
import 'package:shepaw/storage/pouch_session.dart';

void main() {
  PouchSession session() {
    return const PouchSession(
      hubUrl: 'ws://127.0.0.1:18792/peer/ws',
      pouchId: 'pouch-a',
      pouchName: '书房',
      hostPeerId: 'host-1',
      token: 'old-token',
      sessionId: 'sid-old',
      expiresAtMs: 9000,
    );
  }

  PeerControlEvent required({String peerId = 'host-1'}) {
    return PeerControlEvent(
      peerId: peerId,
      data: const {'type': 'pouch_login_required'},
    );
  }

  test('重登成功后换上新 token', () async {
    final events = StreamController<PeerControlEvent>();
    PouchSession? saved;
    PouchSession? installed;
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => session(),
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        return const PouchLoginGrant(
          token: 'new-token',
          sessionId: 'sid-new',
          expiresAtMs: 12000,
        );
      },
      persist: (next) async => saved = next,
      install: (next) => installed = next,
      forgetSession: () async => fail('should keep the session'),
      clearChannel: () => fail('should keep the channel'),
      openChooser: () => fail('should stay on the home page'),
    );
    var heard = 0;
    final sub = keeper.relogged.listen((_) => heard += 1);
    keeper.start();
    events.add(required());
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(saved?.token, 'new-token');
    expect(keeper.reloginGeneration, 1);
    expect(heard, 1);
    await sub.cancel();
    expect(saved?.sessionId, 'sid-new');
    expect(saved?.pouchId, 'pouch-a');
    expect(installed?.token, 'new-token');
    await events.close();
  });

  test('袋子不存在时清掉登录态并回到选择页', () async {
    final events = StreamController<PeerControlEvent>();
    var forgotten = false;
    var cleared = false;
    var opened = false;
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => session(),
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        throw StateError('没有这只袋子');
      },
      persist: (_) async => fail('should not save'),
      install: (_) => fail('should not install'),
      forgetSession: () async => forgotten = true,
      clearChannel: () => cleared = true,
      openChooser: () => opened = true,
    );
    keeper.start();
    events.add(required());
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(forgotten, isTrue);
    expect(cleared, isTrue);
    expect(opened, isTrue);
    await events.close();
  });

  test('同时来的多次要求只发一次登录', () async {
    final events = StreamController<PeerControlEvent>();
    var calls = 0;
    final gate = Completer<void>();
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => session(),
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        calls += 1;
        await gate.future;
        return const PouchLoginGrant(
          token: 'new-token',
          sessionId: 'sid-new',
          expiresAtMs: 12000,
        );
      },
      persist: (_) async {},
      install: (_) {},
      forgetSession: () async {},
      clearChannel: () {},
      openChooser: () {},
    );
    keeper.start();
    events.add(required());
    events.add(required());
    events.add(required());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, 1);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    await events.close();
  });

  test('已经在登录页时，主机要密码不再把页面推掉', () async {
    final events = StreamController<PeerControlEvent>();
    var opened = 0;
    var cleared = false;
    final live = PouchSession(
      hubUrl: 'ws://127.0.0.1:18792/peer/ws',
      pouchId: 'pouch-a',
      pouchName: '书房',
      hostPeerId: 'host-1',
      token: 'old-token',
      sessionId: 'sid-old',
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 60000,
    );
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => live,
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        throw const PouchPasswordRequired('密码不对');
      },
      persist: (_) async => fail('should not save'),
      install: (_) => fail('should not keep the dead session'),
      forgetSession: () async => fail('session file stays until they log in'),
      clearChannel: () => cleared = true,
      openChooser: () => opened += 1,
    );
    keeper.retainGate();
    keeper.start();
    events.add(required());
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(cleared, isTrue);
    expect(opened, 0);
    keeper.releaseGate();
    await events.close();
  });

  test('主机要密码时，没过期的旧登录也要回登录页', () async {
    final events = StreamController<PeerControlEvent>();
    var cleared = false;
    var opened = false;
    final live = PouchSession(
      hubUrl: 'ws://127.0.0.1:18792/peer/ws',
      pouchId: 'pouch-a',
      pouchName: '书房',
      hostPeerId: 'host-1',
      token: 'old-token',
      sessionId: 'sid-old',
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 60000,
    );
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => live,
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        throw const PouchPasswordRequired('密码不对');
      },
      persist: (_) async => fail('should not save'),
      install: (_) => fail('should not keep the dead session'),
      forgetSession: () async => fail('session file stays until they log in'),
      clearChannel: () => cleared = true,
      openChooser: () => opened = true,
    );
    keeper.start();
    events.add(required());
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(cleared, isTrue);
    expect(opened, isTrue);
    await events.close();
  });

  // 主机侧把袋子弄没了（重建主机、换了活动袋子）。本地那张登录就算没过期
  // 也换不出 token 了：留着它，之后每一帧仍然被主机丢掉，界面永远是空的，
  // 也不会有任何提示。必须清掉再回选择页。
  test('袋子没了时，没过期的旧登录也要清掉并回选择页', () async {
    final events = StreamController<PeerControlEvent>();
    var forgotten = false;
    var cleared = false;
    var opened = false;
    final live = PouchSession(
      hubUrl: 'ws://127.0.0.1:18792/peer/ws',
      pouchId: 'pouch-a',
      pouchName: '书房',
      hostPeerId: 'host-1',
      token: 'old-token',
      sessionId: 'sid-old',
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 60000,
    );
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => live,
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        throw StateError('没有这只袋子');
      },
      persist: (_) async => fail('should not save'),
      install: (_) => fail('should not keep the dead session'),
      forgetSession: () async => forgotten = true,
      clearChannel: () => cleared = true,
      openChooser: () => opened = true,
    );
    keeper.start();
    events.add(required());
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(forgotten, isTrue);
    expect(cleared, isTrue);
    expect(opened, isTrue);
    await events.close();
  });

  // 主机只是暂时连不上（抖动、重启中）。袋子还在，登录态也还没过期，
  // 这时候清掉登录态反而把用户踢回选择页。
  test('暂时连不上主机时，没过期的登录态保留', () async {
    final events = StreamController<PeerControlEvent>();
    PouchSession? installed;
    final live = PouchSession(
      hubUrl: 'ws://127.0.0.1:18792/peer/ws',
      pouchId: 'pouch-a',
      pouchName: '书房',
      hostPeerId: 'host-1',
      token: 'old-token',
      sessionId: 'sid-old',
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 60000,
    );
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => live,
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        throw StateError('还没连上 shepaw');
      },
      persist: (_) async => fail('should not save'),
      install: (next) => installed = next,
      forgetSession: () async => fail('should keep the session'),
      clearChannel: () => fail('should keep the channel'),
      openChooser: () => fail('should stay'),
    );
    keeper.start();
    events.add(required());
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(installed?.token, 'old-token');
    await events.close();
  });

  Future<PouchCredentialStore> credentialStore({
    String credential = 'cred-1',
    Duration ttl = const Duration(minutes: 30),
  }) async {
    final store = PouchCredentialStore(vault: MemoryPouchCredentialVault());
    await store.save(
      hostPeerId: 'host-1',
      pouchId: 'pouch-a',
      credential: credential,
      expiresAtMs:
          DateTime.now().add(ttl).millisecondsSinceEpoch,
    );
    return store;
  }

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  test('主机重启后先用设备凭据恢复，不碰密码', () async {
    final events = StreamController<PeerControlEvent>();
    final store = await credentialStore();
    String? used;
    PouchSession? installed;
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => session(),
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        used = credential;
        return const PouchLoginGrant(
          token: 'new-token',
          sessionId: 'sid-new',
          expiresAtMs: 12000,
          credential: 'cred-2',
          credentialExpiresAtMs: 99000,
        );
      },
      persist: (_) async {},
      install: (next) => installed = next,
      forgetSession: () async => fail('should keep the session'),
      clearChannel: () => fail('should keep the channel'),
      openChooser: () => fail('should not open the gate'),
      credentials: store,
    );
    keeper.start();
    events.add(required());
    await settle();
    expect(used, 'cred-1');
    expect(installed?.token, 'new-token');
    expect(keeper.reloginGeneration, 1);
    expect(keeper.passwordRequired.value, isFalse);
    // 密码登录换发的新凭据要接着用。
    final saved = await store.read('host-1');
    expect(saved?.credential, 'cred-2');
    expect(saved?.expiresAtMs, 99000);
    await events.close();
  });

  test('凭据被主机拒绝：删掉本机这张，改用密码再试一次', () async {
    final events = StreamController<PeerControlEvent>();
    final store = await credentialStore();
    final calls = <String?>[];
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => session(),
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        calls.add(credential);
        if (credential != null) {
          throw const PouchCredentialRejected('设备凭据已失效');
        }
        return const PouchLoginGrant(
          token: 'new-token',
          sessionId: 'sid-new',
          expiresAtMs: 12000,
        );
      },
      persist: (_) async {},
      install: (_) {},
      forgetSession: () async => fail('should keep the session'),
      clearChannel: () => fail('should keep the channel'),
      openChooser: () => fail('should not open the gate'),
      credentials: store,
    );
    keeper.start();
    events.add(required());
    await settle();
    expect(calls, ['cred-1', null]);
    expect(await store.read('host-1'), isNull);
    expect(keeper.reloginGeneration, 1);
    expect(keeper.passwordRequired.value, isFalse);
    await events.close();
  });

  test('凭据失效又没密码：提示条亮起并回登录页', () async {
    final events = StreamController<PeerControlEvent>();
    final store = await credentialStore();
    var cleared = false;
    var opened = false;
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => session(),
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        if (credential != null) {
          throw const PouchCredentialRejected('设备凭据已失效');
        }
        throw const PouchPasswordRequired('密码不对');
      },
      persist: (_) async => fail('should not save'),
      install: (_) => fail('should not install'),
      forgetSession: () async => fail('session file stays until they log in'),
      clearChannel: () => cleared = true,
      openChooser: () => opened = true,
      credentials: store,
    );
    keeper.start();
    events.add(required());
    await settle();
    expect(cleared, isTrue);
    expect(opened, isTrue);
    expect(keeper.passwordRequired.value, isTrue);
    expect(await store.read('host-1'), isNull);
    await events.close();
  });

  test('恢复成功一次，提示条自动收起', () async {
    final events = StreamController<PeerControlEvent>();
    final store = PouchCredentialStore(vault: MemoryPouchCredentialVault());
    var hasCredential = false;
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => session(),
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        if (!hasCredential) {
          throw const PouchPasswordRequired('密码不对');
        }
        return const PouchLoginGrant(
          token: 'new-token',
          sessionId: 'sid-new',
          expiresAtMs: 12000,
        );
      },
      persist: (_) async {},
      install: (_) {},
      forgetSession: () async {},
      clearChannel: () {},
      openChooser: () => fail('already on the gate'),
      credentials: store,
    );
    keeper.retainGate();
    keeper.start();
    events.add(required());
    await settle();
    expect(keeper.passwordRequired.value, isTrue);

    // 用户在登录页重新登录成功后，keeper 才重新允许自动恢复。
    final generation = keeper.reloginGeneration;
    keeper.clearPasswordRequired();
    hasCredential = true;
    await store.save(
      hostPeerId: 'host-1',
      pouchId: 'pouch-a',
      credential: 'cred-new',
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 60000,
    );
    events.add(required());
    await settle();
    expect(keeper.passwordRequired.value, isFalse);
    expect(keeper.reloginGeneration, generation + 1);
    keeper.releaseGate();
    await events.close();
  });

  test('主机要密码后停止自动重试，避免反复烧主机限流额度', () async {
    final events = StreamController<PeerControlEvent>();
    var calls = 0;
    var opened = 0;
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => session(),
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        calls += 1;
        throw const PouchPasswordRequired('密码不对');
      },
      persist: (_) async => fail('should not save'),
      install: (_) => fail('should not install'),
      forgetSession: () async => fail('should keep the session'),
      clearChannel: () {},
      openChooser: () => opened += 1,
    );
    keeper.start();
    events.add(required());
    await settle();
    expect(calls, 1);
    expect(opened, 1);
    expect(keeper.passwordRequired.value, isTrue);

    // 用户还没重新登录，主机继续发 pouch_login_required 也不能自动再试。
    events.add(required());
    events.add(required());
    await settle();
    expect(calls, 1);
    expect(opened, 1);
    await events.close();
  });

  test('网络失败后退避，不会立刻重复重登', () async {
    final events = StreamController<PeerControlEvent>();
    var calls = 0;
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => session(),
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        calls += 1;
        throw TimeoutException('login');
      },
      persist: (_) async => fail('should not save'),
      install: (_) => fail('should not install'),
      forgetSession: () async => fail('should keep the session'),
      clearChannel: () => fail('should not clear'),
      openChooser: () => fail('should not leave'),
    );
    keeper.start();
    events.add(required());
    await settle();
    expect(calls, 1);
    events.add(required());
    await settle();
    expect(calls, 1, reason: '2 秒退避窗口内不再重试');
    await events.close();
  });

  test('网络抖动不清凭据，下次还能试', () async {
    final events = StreamController<PeerControlEvent>();
    final store = await credentialStore();
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => session(),
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        throw TimeoutException('login');
      },
      persist: (_) async => fail('should not save'),
      install: (_) => fail('should not install'),
      forgetSession: () async => fail('should keep the session'),
      clearChannel: () => fail('should not clear'),
      openChooser: () => fail('should not leave'),
      credentials: store,
    );
    keeper.start();
    events.add(required());
    await settle();
    expect((await store.read('host-1'))?.credential, 'cred-1');
    expect(keeper.passwordRequired.value, isFalse);
    await events.close();
  });

  test('过期的凭据不拿去试，直接走密码', () async {
    final events = StreamController<PeerControlEvent>();
    final store = await credentialStore(
      ttl: const Duration(seconds: -1),
    );
    String? used = 'unset';
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => session(),
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        used = credential;
        throw const PouchPasswordRequired('密码不对');
      },
      persist: (_) async => fail('should not save'),
      install: (_) => fail('should not install'),
      forgetSession: () async {},
      clearChannel: () {},
      openChooser: () {},
      credentials: store,
    );
    keeper.retainGate();
    keeper.start();
    events.add(required());
    await settle();
    expect(used, isNull);
    keeper.releaseGate();
    await events.close();
  });

  test('网络超时不清登录态', () async {
    final events = StreamController<PeerControlEvent>();
    var forgotten = false;
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => session(),
      login: ({
        required hostPeerId,
        required pouchId,
        String? credential,
      }) async {
        throw TimeoutException('login');
      },
      persist: (_) async => fail('should not save'),
      install: (_) => fail('should not install'),
      forgetSession: () async => forgotten = true,
      clearChannel: () => fail('should not clear'),
      openChooser: () => fail('should not leave'),
    );
    keeper.start();
    events.add(required());
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(forgotten, isFalse);
    await events.close();
  });
}
