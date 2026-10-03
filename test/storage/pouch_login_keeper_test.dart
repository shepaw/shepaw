import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
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
      login: ({required hostPeerId, required pouchId}) async {
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
    keeper.start();
    events.add(required());
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(saved?.token, 'new-token');
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
      login: ({required hostPeerId, required pouchId}) async {
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
      login: ({required hostPeerId, required pouchId}) async {
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

  test('网络超时不清登录态', () async {
    final events = StreamController<PeerControlEvent>();
    var forgotten = false;
    final keeper = PouchLoginKeeper(
      events: events.stream,
      readSession: () async => session(),
      login: ({required hostPeerId, required pouchId}) async {
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
