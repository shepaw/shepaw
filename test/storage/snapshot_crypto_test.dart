import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/snapshot_crypto.dart';

import 'test_harness.dart';

/// 快照加密层（docs/storage_space_plan.md §5.2，M3 两级 KDF）：
/// H = PBKDF2(主密码)（可缓存）；key = HMAC(H, snapshot_salt)。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
  });

  group('两级 KDF', () {
    test('加密/解密往返', () async {
      final salt = SnapshotCrypto.newSnapshotSalt();
      final key =
          await SnapshotCrypto.deriveKeyFromPassword('correct horse', salt);
      final plain = Uint8List.fromList(List.generate(4096, (i) => i % 251));
      final packed = await SnapshotCrypto.encrypt(plain, key);
      expect(packed.length, greaterThan(plain.length));
      expect(await SnapshotCrypto.decrypt(packed, key), plain);
    });

    test('缓存的 H 与慢路径派生同一密钥（自动快照与手动恢复同钥）', () async {
      final salt = SnapshotCrypto.newSnapshotSalt();
      final h = await SnapshotCrypto.hashPassword('pw');
      await SnapshotCrypto.cachePasswordHash(h);

      final cached = await SnapshotCrypto.cachedPasswordHash();
      expect(cached, h);

      final kFast = await SnapshotCrypto.deriveKeyFromHash(cached!, salt);
      final kSlow = await SnapshotCrypto.deriveKeyFromPassword('pw', salt);
      final plain = Uint8List.fromList([1, 2, 3]);
      final packed = await SnapshotCrypto.encrypt(plain, kFast);
      expect(await SnapshotCrypto.decrypt(packed, kSlow), plain);
    });

    test('不同 snapshot salt 派生不同密钥（换机后凭主密码+manifest salt 重建）',
        () async {
      final h = await SnapshotCrypto.hashPassword('pw');
      final k1 = await SnapshotCrypto.deriveKeyFromHash(
          h, SnapshotCrypto.newSnapshotSalt());
      final k2 = await SnapshotCrypto.deriveKeyFromHash(
          h, SnapshotCrypto.newSnapshotSalt());
      final plain = Uint8List.fromList([9, 9, 9]);
      final packed = await SnapshotCrypto.encrypt(plain, k1);
      expect(() => SnapshotCrypto.decrypt(packed, k2),
          throwsA(isA<SnapshotDecryptException>()));
    });

    test('密码错误抛 SnapshotDecryptException', () async {
      final salt = SnapshotCrypto.newSnapshotSalt();
      final good = await SnapshotCrypto.deriveKeyFromPassword('right', salt);
      final bad = await SnapshotCrypto.deriveKeyFromPassword('wrong', salt);
      final packed = await SnapshotCrypto.encrypt(Uint8List(64), good);
      expect(() => SnapshotCrypto.decrypt(packed, bad),
          throwsA(isA<SnapshotDecryptException>()));
    });

    test('密文被篡改抛 SnapshotDecryptException', () async {
      final salt = SnapshotCrypto.newSnapshotSalt();
      final key = await SnapshotCrypto.deriveKeyFromPassword('pw2', salt);
      final packed = await SnapshotCrypto.encrypt(
          Uint8List.fromList(List.generate(128, (i) => i)), key);
      packed[packed.length - 20] ^= 0xFF;
      expect(() => SnapshotCrypto.decrypt(packed, key),
          throwsA(isA<SnapshotDecryptException>()));
    });

    test('M1 旧格式（设备 salt）兼容解密', () async {
      final key = await SnapshotCrypto.deriveLegacyKey('pw3');
      final plain = Uint8List.fromList([7, 7, 7]);
      final packed = await SnapshotCrypto.encrypt(plain, key);
      final key2 = await SnapshotCrypto.deriveLegacyKey('pw3');
      expect(await SnapshotCrypto.decrypt(packed, key2), plain);
    });
  });
}
