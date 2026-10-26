import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_connection.dart';

void main() {
  // 主机 `peer-identity.json` 里那把 key 和它报出来的 fingerprint。两边算法
  // 一旦分叉，握手会以「4403 handshake key mismatch」的形式失败，日志里只看
  // 得出「key 不对」，看不出是算错了。
  const hostPublicKey = '6gvwAFfchX/skvU20/uYpJR4pCJN7Xomx0UAd76Pdks=';
  const hostFingerprint = 'c1b74877debb2fd6';

  test('fingerprint is sha256(pubkey) 前 8 字节，与主机一致', () {
    final key = Uint8List.fromList(base64.decode(hostPublicKey));
    expect(peerKeyFingerprint(key), hostFingerprint);
  });

  test('不同公钥给出不同指纹', () {
    final key = Uint8List.fromList(base64.decode(hostPublicKey));
    final other = Uint8List.fromList(key)..[0] ^= 0xff;
    expect(peerKeyFingerprint(other), isNot(hostFingerprint));
  });
}
