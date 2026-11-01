import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/onboarding/credential_restore.dart';
import 'package:shepaw/peer/models/paired_peer.dart';
import 'package:shepaw/storage/pouch_login_client.dart';
import 'package:shepaw/storage/pouch_session.dart';

PouchSession session({
  String hostPeerId = 'peer-1',
  String pouchId = 'pouch-a',
  int expiresAtMs = 0,
}) {
  return PouchSession(
    hubUrl: 'ws://127.0.0.1:18794/peer/ws',
    pouchId: pouchId,
    pouchName: '书房',
    hostPeerId: hostPeerId,
    token: 'old-token',
    sessionId: 'old-sid',
    expiresAtMs: expiresAtMs,
  );
}

PairedPeer peer(String id) {
  return PairedPeer(
    id: id,
    deviceName: 'EDENZOU-MB2',
    deviceId: 'dev-$id',
    publicKey: Uint8List.fromList(List<int>.filled(32, 7)),
    fingerprint: 'fp-$id',
    channelEndpoint: null,
    localEndpoint: 'ws://127.0.0.1:18794/peer/ws',
    pairedAt: 1759276800000,
    lastSeen: null,
    platform: 'macos',
    form: 'desktop',
  );
}

PouchLoginGrant grant({String credential = 'new-credential'}) {
  return PouchLoginGrant(
    token: 'new-token',
    sessionId: 'new-sid',
    expiresAtMs: 123456,
    credential: credential,
    credentialExpiresAtMs: 999,
  );
}

class Harness {
  Harness({
    this.current,
    this.credential = 'saved-credential',
    this.connectFailures = 0,
    this.loginError,
  });

  final PouchSession? current;
  final String? credential;

  /// 前几次连接抛 TimeoutException，之后成功。
  int connectFailures;

  final Object? loginError;

  final List<PouchSession> persisted = [];
  final List<PouchSession> installed = [];
  final List<String> dropped = [];
  final List<String> savedCredentials = [];
  final List<String> log = [];
  int connectCalls = 0;
  int loginCalls = 0;
  final List<bool> redials = [];

  CredentialRestore build() {
    return CredentialRestore(
      readSession: () async => current,
      lookupPeer: (id) async => peer(id),
      readCredential: ({required hostPeerId, required pouchId, required nowMs}) async {
        if (pouchId != current?.pouchId) return null;
        return credential;
      },
      connect: (p, {required bool redial}) async {
        connectCalls++;
        redials.add(redial);
        if (connectCalls <= connectFailures) {
          throw TimeoutException('连不上', const Duration(seconds: 4));
        }
      },
      login: ({required hostPeerId, required pouchId, required credential}) async {
        loginCalls++;
        final error = loginError;
        if (error != null) throw error;
        return grant();
      },
      persist: (next) async {
        persisted.add(next);
      },
      install: (next) {
        installed.add(next);
      },
      saveCredential: ({
        required hostPeerId,
        required pouchId,
        required credential,
        required int expiresAtMs,
      }) async {
        savedCredentials.add(credential);
      },
      dropCredential: (hostPeerId) async {
        dropped.add(hostPeerId);
      },
      log: log.add,
    );
  }
}

void main() {
  test('续期成功：写会话、装通道、存新凭据', () async {
    final harness = Harness(current: session());
    final result = await harness.build().run(hostPeerId: 'peer-1');
    expect(result, RestoreResult.restored);
    expect(harness.persisted.single.token, 'new-token');
    expect(harness.persisted.single.sessionId, 'new-sid');
    expect(harness.installed.single.token, 'new-token');
    expect(harness.savedCredentials, ['new-credential']);
    expect(harness.dropped, isEmpty);
  });

  test('没有登录态就不折腾', () async {
    final harness = Harness();
    expect(
      await harness.build().run(hostPeerId: 'peer-1'),
      RestoreResult.none,
    );
    expect(harness.connectCalls, 0);
    expect(harness.loginCalls, 0);
  });

  test('没有凭据就不折腾', () async {
    final harness = Harness(current: session(), credential: null);
    expect(
      await harness.build().run(hostPeerId: 'peer-1'),
      RestoreResult.none,
    );
    expect(harness.loginCalls, 0);
  });

  test('会话的主机对不上就不续期', () async {
    final harness = Harness(current: session());
    expect(
      await harness.build().run(hostPeerId: 'peer-other'),
      RestoreResult.none,
    );
    expect(harness.loginCalls, 0);
  });

  test('凭据被主机拒绝：删掉本机这张，返回 rejected', () async {
    final harness = Harness(
      current: session(),
      loginError: const PouchCredentialRejected('设备凭据已失效'),
    );
    expect(
      await harness.build().run(hostPeerId: 'peer-1'),
      RestoreResult.rejected,
    );
    expect(harness.dropped, ['peer-1']);
    expect(harness.persisted, isEmpty);
  });

  test('连不上主机：不发登录，凭据保留', () async {
    final harness = Harness(current: session(), connectFailures: 99);
    expect(
      await harness.build().run(hostPeerId: 'peer-1'),
      RestoreResult.unreachable,
    );
    // 连接给了两次机会，第二次是断开重连。
    expect(harness.connectCalls, 2);
    expect(harness.redials, [false, true]);
    expect(harness.loginCalls, 0);
    expect(harness.dropped, isEmpty);
  });

  test('第一次超时、第二次连上，照样续期', () async {
    final harness = Harness(current: session(), connectFailures: 1);
    expect(
      await harness.build().run(hostPeerId: 'peer-1'),
      RestoreResult.restored,
    );
    expect(harness.redials, [false, true]);
    expect(harness.loginCalls, 1);
  });

  test('登录超时算 unreachable，不删凭据', () async {
    final harness = Harness(
      current: session(),
      loginError: TimeoutException('主机没回', const Duration(seconds: 3)),
    );
    expect(
      await harness.build().run(hostPeerId: 'peer-1'),
      RestoreResult.unreachable,
    );
    expect(harness.dropped, isEmpty);
  });

  test('预算耗尽就放弃，不会把人晾在启动页', () async {
    final harness = Harness(current: session(), connectFailures: 99);
    final sw = Stopwatch()..start();
    final result = await harness.build().run(
      hostPeerId: 'peer-1',
      budget: const Duration(milliseconds: 300),
    );
    sw.stop();
    expect(result, RestoreResult.unreachable);
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('renew 不负责连接：keeper 在已有连接上用它', () async {
    final harness = Harness(current: session());
    expect(
      await harness.build().renew(hostPeerId: 'peer-1'),
      RestoreResult.restored,
    );
    expect(harness.connectCalls, 0);
    expect(harness.loginCalls, 1);
  });

  test('renew 没有凭据返回 none，交给 keeper 去要密码', () async {
    final harness = Harness(current: session(), credential: null);
    expect(
      await harness.build().renew(hostPeerId: 'peer-1'),
      RestoreResult.none,
    );
  });
}
