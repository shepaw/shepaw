import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/models/pairing_payload.dart';
import 'package:shepaw/peer/pouch_pair.dart';

void main() {
  final publicKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));

  PeerPairingInfo info({String? inviteId}) {
    return PeerPairingInfo(
      localEndpoint: 'ws://192.168.1.5:18793/peer/ws',
      code: 'ABCD2345',
      fingerprint: PeerPairingInfoFingerprint.of(publicKey),
      publicKey: publicKey,
      name: 'EDENZOU-MB2',
      inviteId: inviteId,
    );
  }

  test('inv 参数往返：编码之后还能解析回来', () {
    final encoded = PeerPairingInfo.encode(
      localEndpoint: 'ws://192.168.1.5:18793/peer/ws',
      code: 'ABCD2345',
      fingerprint: PeerPairingInfoFingerprint.of(publicKey),
      publicKey: publicKey,
      name: 'EDENZOU-MB2',
      inviteId: 'inv-abc',
    );
    final parsed = PeerPairingInfo.tryParse(encoded);
    expect(parsed, isNotNull);
    expect(parsed!.inviteId, 'inv-abc');
    expect(parsed.code, 'ABCD2345');
    expect(parsed.name, 'EDENZOU-MB2');
  });

  test('没有 inv 的链接照样能解析，inviteId 为 null', () {
    final encoded = PeerPairingInfo.encode(
      localEndpoint: 'ws://192.168.1.5:18793/peer/ws',
      code: 'ABCD2345',
      fingerprint: PeerPairingInfoFingerprint.of(publicKey),
      publicKey: publicKey,
      name: 'EDENZOU-MB2',
    );
    expect(encoded.contains('inv='), isFalse);
    final parsed = PeerPairingInfo.tryParse(encoded);
    expect(parsed, isNotNull);
    expect(parsed!.inviteId, isNull);
  });

  test('把票据交给主机时邀请编号不会被丢掉', () {
    final ticket = PouchPairTicket.encode(info(inviteId: 'inv-xyz'));
    expect(PouchPairTicket.decode(ticket).inviteId, 'inv-xyz');
  });
}

/// `PeerPairingInfo` 要求 fingerprint 等于公钥哈希，所以这里算一份出来。
class PeerPairingInfoFingerprint {
  static String of(Uint8List publicKey) {
    final digest = crypto.sha256.convert(publicKey).bytes;
    final sb = StringBuffer();
    for (var i = 0; i < 8; i++) {
      sb.write(digest[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
