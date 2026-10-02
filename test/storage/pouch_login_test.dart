import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/pouch_login.dart';
import 'package:shepaw/storage/pouch_session.dart';

void main() {
  PouchSession live({int expiresAtMs = 9000}) {
    return PouchSession(
      hubUrl: 'http://127.0.0.1:1',
      pouchId: 'pouch-a',
      pouchName: '书房',
      hostPeerId: 'peer-1',
      token: 'login-token',
      sessionId: 'sid-1',
      expiresAtMs: expiresAtMs,
    );
  }

  tearDown(PouchChannel.clear);

  test('手机和电脑共用：有未过期 token 进主页，否则去登录袋子', () {
    expect(afterDeviceUnlock(null, nowMs: 10), AppStart.pouchLogin);
    expect(afterDeviceUnlock(live(), nowMs: 10), AppStart.home);
    expect(
      afterDeviceUnlock(live(expiresAtMs: 10), nowMs: 10),
      AppStart.pouchLogin,
    );
    expect(
      afterDeviceUnlock(
        const PouchSession(
          hubUrl: 'http://127.0.0.1:1',
          pouchId: 'pouch-a',
          pouchName: '书房',
          hostPeerId: 'peer-1',
        ),
        nowMs: 10,
      ),
      AppStart.pouchLogin,
    );
  });

  test('登录态写进文件后还能读回来', () async {
    final dir = await Directory.systemTemp.createTemp('pouch_session_');
    final vault = MemoryPouchTokenVault();
    final store = PouchSessionStore(
      File('${dir.path}/pouch_session.json'),
      vault: vault,
    );
    await store.save(live());
    final text = await store.file.readAsString();
    expect(text.contains('login-token'), isFalse);
    expect(vault.values['sid-1'], 'login-token');
    final loaded = await store.load();
    expect(loaded?.token, 'login-token');
    expect(loaded?.sessionId, 'sid-1');
    expect(loaded?.isLoggedIn(10), isTrue);

    await store.file.writeAsString(text.replaceFirst(
      '"sid":"sid-1"',
      '"sid":"sid-1","token":"legacy-token"',
    ));
    final migrated = await store.load();
    expect(migrated?.token, 'legacy-token');
    expect((await store.file.readAsString()).contains('legacy-token'), isFalse);

    await store.forget();
    expect(store.file.existsSync(), isFalse);
    expect(vault.values.containsKey('sid-1'), isFalse);
    await dir.delete(recursive: true);
  });

  test('密封帧用登录 token 派生的密钥，换袋子解不开', () async {
    PouchChannel.install(live(
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 60000,
    ));
    final sealed = await PouchChannel.active!.seal(
      <String, dynamic>{'type': 'she'},
      nonce: Uint8List(12)..fillRange(0, 12, 7),
    );
    expect(sealed['type'], 'pouch_sealed');
    expect(sealed['sid'], 'sid-1');
    expect(sealed['n'], 'BwcHBwcHBwcHBwcH');
    expect(sealed['c'], 'ddc6b7UJkEav3g_-H-5UWA5DKK_wdx_gesgpEw_F');

    final opened = await PouchChannel.openIfSealed(sealed);
    expect(opened['type'], 'she');

    final stolen = Map<String, dynamic>.from(sealed);
    stolen['pouch_id'] = 'pouch-b';
    await expectLater(
      PouchChannel.active!.open(stolen),
      throwsStateError,
    );
  });

  test('心跳、登录和 Hub 要提前对上的回包不密封', () {
    expect(loginSealRequired('ping'), isFalse);
    expect(loginSealRequired('pouch_login'), isFalse);
    expect(loginSealRequired('cli_execute_resp'), isFalse);
    expect(loginSealRequired('session_create_resp'), isFalse);
    expect(loginSealRequired('pouch', op: 'result'), isFalse);
    expect(loginSealRequired('pouch', op: 'error'), isFalse);
    expect(loginSealRequired('pouch', op: 'read'), isTrue);
    expect(loginSealRequired('fs_browse_req'), isTrue);
    expect(loginSealRequired('pouch_pair_req'), isTrue);
    expect(loginSealRequired('agent_chat'), isTrue);
    expect(loginSealRequired('she'), isTrue);
  });

  test('没有登录态时业务帧保持原样', () async {
    final frame = await PouchChannel.sealIfNeeded(
      <String, dynamic>{'type': 'agent_chat', 'text': 'hi'},
    );
    expect(jsonEncode(frame), contains('agent_chat'));
    expect(frame.containsKey('c'), isFalse);
  });
}
