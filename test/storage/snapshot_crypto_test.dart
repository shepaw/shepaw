import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/snapshot_crypto.dart';

import 'test_harness.dart';

/// 快照加密层（docs/storage_space_plan.md §5.2）：
/// XChaCha20-Poly1305 + PBKDF2(主密码, 设备 salt)。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
  });

  group('SnapshotCrypto', () {
    test('加密/解密往返', () async {
      final key = await SnapshotCrypto.deriveKey('correct horse');
      final plain = Uint8List.fromList(List.generate(4096, (i) => i % 251));
      final packed = await SnapshotCrypto.encrypt(plain, key);
      expect(packed.length, greaterThan(plain.length)); // nonce + mac
      final back = await SnapshotCrypto.decrypt(packed, key);
      expect(back, plain);
    });

    test('同一密码派生同一密钥（设备 salt 稳定）', () async {
      final k1 = await SnapshotCrypto.deriveKey('pw');
      final k2 = await SnapshotCrypto.deriveKey('pw');
      final plain = Uint8List.fromList([1, 2, 3]);
      final packed = await SnapshotCrypto.encrypt(plain, k1);
      expect(await SnapshotCrypto.decrypt(packed, k2), plain);
    });

    test('密码错误抛 SnapshotDecryptException', () async {
      final good = await SnapshotCrypto.deriveKey('right');
      final bad = await SnapshotCrypto.deriveKey('wrong');
      final packed = await SnapshotCrypto.encrypt(Uint8List(64), good);
      expect(() => SnapshotCrypto.decrypt(packed, bad),
          throwsA(isA<SnapshotDecryptException>()));
    });

    test('密文被篡改抛 SnapshotDecryptException', () async {
      final key = await SnapshotCrypto.deriveKey('pw2');
      final packed = await SnapshotCrypto.encrypt(
          Uint8List.fromList(List.generate(128, (i) => i)), key);
      packed[packed.length - 20] ^= 0xFF; // 翻转载荷一字节
      expect(() => SnapshotCrypto.decrypt(packed, key),
          throwsA(isA<SnapshotDecryptException>()));
    });
  });
}
