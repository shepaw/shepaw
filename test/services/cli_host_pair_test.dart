import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/models/pairing_payload.dart';
import 'package:shepaw/services/cli_host.dart';

void main() {
  final key = Uint8List(32);
  final link = PeerPairingInfo.encode(
    localEndpoint: 'ws://127.0.0.1:18794/peer/ws',
    code: 'ABCD2345',
    fingerprint: '66687aadf862bd77',
    publicKey: key,
    name: 'EDENZOU-MB2',
  );

  test('pair --json 的 link 能解析成配对票据', () {
    final stdout = jsonEncode({
      'link': link,
      'code': 'ABCD2345',
      'expires_at_ms': 1700000000000,
      'endpoint': 'ws://127.0.0.1:18794/peer/ws',
      'name': 'EDENZOU-MB2',
    });
    final info = pairingInfoFromOutput(stdout);
    expect(info, isNotNull);
    expect(info!.code, 'ABCD2345');
    expect(info.localEndpoint, 'ws://127.0.0.1:18794/peer/ws');
    expect(info.displayName, 'EDENZOU-MB2');
  });

  test('旧版本直接打印的 shepaw:// 行仍然能用', () {
    final info = pairingInfoFromOutput('code: ABCD2345\n$link\n');
    expect(info, isNotNull);
    expect(info!.fingerprint, '66687aadf862bd77');
  });
}
