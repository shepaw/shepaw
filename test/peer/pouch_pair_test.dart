import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/models/pairing_payload.dart';
import 'package:shepaw/peer/pouch_pair.dart';
import 'package:shepaw/peer/services/peer_pairing_service.dart';

void main() {
  test('二维码就是当前主机时，握手留在本机', () {
    expect(
      pouchPairRunsLocal(
        runLocal: false,
        hostFingerprint: 'C1B74877DEBB2FD6',
        qrFingerprint: 'c1b74877debb2fd6',
      ),
      isTrue,
    );
    expect(
      pouchPairRunsLocal(
        runLocal: false,
        hostFingerprint: 'aaaaaaaaaaaaaaaa',
        qrFingerprint: 'c1b74877debb2fd6',
      ),
      isFalse,
    );
    expect(
      pouchPairRunsLocal(
        runLocal: true,
        hostFingerprint: null,
        qrFingerprint: 'c1b74877debb2fd6',
      ),
      isTrue,
    );
  });

  test('主机代连时先走外网端点', () {
    final info = PeerPairingInfo(
      localEndpoint: 'ws://192.168.1.9/peer/ws',
      channelEndpoint: 'wss://channel.example/peer/ws',
      code: 'ABCD1234',
      fingerprint: '0011223344556677',
      publicKey: Uint8List(32),
    );

    expect(
      info.connectOrder().map((e) => e.channel).toList(),
      [false, true],
    );
    expect(
      info.connectOrder(preferChannel: true).map((e) => e.url).toList(),
      ['wss://channel.example/peer/ws', 'ws://192.168.1.9/peer/ws'],
    );
    expect(
      PeerPairingInfo(
        channelEndpoint: 'wss://only',
        code: 'ABCD1234',
        fingerprint: '0011223344556677',
        publicKey: Uint8List(32),
      ).connectOrder(preferChannel: true).single.url,
      'wss://only',
    );
  });

  test('票据往返后指纹仍等于公钥，改过的指纹作废', () {
    final key = Uint8List(32)..[0] = 9;
    final digest = crypto.sha256.convert(key).bytes;
    final fingerprint =
        digest.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final info = PeerPairingInfo(
      localEndpoint: 'ws://192.168.1.9/peer/ws',
      channelEndpoint: 'wss://channel.example/peer/ws',
      code: 'ABCD1234',
      fingerprint: fingerprint,
      publicKey: key,
      name: '书房',
    );

    final decoded = PouchPairTicket.decode(PouchPairTicket.encode(info));
    expect(decoded.fingerprint, fingerprint);
    expect(decoded.code, 'ABCD1234');
    expect(decoded.channelEndpoint, 'wss://channel.example/peer/ws');
    expect(decoded.displayName, '书房');

    final tampered = Map<String, dynamic>.from(PouchPairTicket.encode(info));
    tampered['qr'] = (tampered['qr'] as String)
        .replaceFirst(fingerprint, 'ffffffffffffffff');
    expect(() => PouchPairTicket.decode(tampered), throwsFormatException);
  });

  test('收到 login_required 后等 relogged 再重发一次', () async {
    var calls = 0;
    var generation = 0;
    final result = await sendWithReloginRetry(
      retryOnRelogin: true,
      reloginGeneration: () => generation,
      waitForRelogin: (seen) async {
        expect(seen, 0);
        generation = 1;
      },
      send: () async {
        calls += 1;
        if (calls == 1) throw const PouchLoginRequired();
        return {'ok': true, 'peers': <Object>[]};
      },
    );

    expect(result['ok'], isTrue);
    expect(calls, 2);
  });

  test('重登没有发生就不再发第三次', () async {
    var calls = 0;
    await expectLater(
      sendWithReloginRetry(
        retryOnRelogin: true,
        reloginGeneration: () => 0,
        waitForRelogin: (_) async {},
        send: () async {
          calls += 1;
          throw const PouchLoginRequired();
        },
      ),
      throwsA(isA<PouchLoginRequired>()),
    );
    expect(calls, 2);
  });

  test('等不到重登时改报超时', () async {
    await expectLater(
      sendWithReloginRetry<Map<String, dynamic>>(
        retryOnRelogin: true,
        reloginGeneration: () => 0,
        waitForRelogin: (_) =>
            Future<void>.error(TimeoutException('relogin')),
        send: () async => throw const PouchLoginRequired(),
      ),
      throwsA(isA<PairingTimeoutException>()),
    );
  });

  test('名单超时是 10 秒，确认配对仍等 6 分钟', () {
    expect(PouchPairRelay.listTimeout, const Duration(seconds: 10));
    expect(PouchPairRelay.forwardTimeout, const Duration(minutes: 6));
  });

  test('配对控制帧写进了连接放行名单', () {
    final source =
        File('lib/peer/services/peer_connection.dart').readAsStringSync();
    for (final type in PouchPair.controlTypes) {
      expect(source, contains("'$type'"), reason: type);
    }
  });
}
