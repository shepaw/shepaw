import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/pouch_credential_store.dart';

import 'test_harness.dart';

void main() {
  setUpAll(StorageTestHarness.init);

  test('存进去、读出来、删掉', () async {
    final store = PouchCredentialStore();
    await store.save(
      hostPeerId: 'host-roundtrip',
      pouchId: 'pouch-a',
      credential: 'secret-credential',
      expiresAtMs: 123456,
    );
    final saved = await store.read('host-roundtrip');
    expect(saved?.pouchId, 'pouch-a');
    expect(saved?.credential, 'secret-credential');
    expect(saved?.expiresAtMs, 123456);

    await store.delete('host-roundtrip');
    expect(await store.read('host-roundtrip'), isNull);
  });

  test('没有存过、主机 id 为空都读不到', () async {
    final store = PouchCredentialStore();
    expect(await store.read('host-never-saved'), isNull);
    expect(await store.read('   '), isNull);
  });

  test('每台主机各存一份，互不覆盖', () async {
    final store = PouchCredentialStore();
    await store.save(
      hostPeerId: 'host-one',
      pouchId: 'pouch-a',
      credential: 'one',
    );
    await store.save(
      hostPeerId: 'host-two',
      pouchId: 'pouch-b',
      credential: 'two',
    );
    expect((await store.read('host-one'))?.credential, 'one');
    expect((await store.read('host-two'))?.credential, 'two');
  });

  test('过期判断', () {
    const credential = PouchCredential(
      pouchId: 'pouch-a',
      credential: 'c',
      expiresAtMs: 1000,
    );
    expect(credential.isExpired(999), isFalse);
    expect(credential.isExpired(1000), isTrue);
    // 主机没给过期时间时交给主机判断。
    const noExpiry = PouchCredential(pouchId: 'pouch-a', credential: 'c');
    expect(noExpiry.isExpired(999999999999), isFalse);
  });

  test('存坏了的 JSON 当作没有凭据', () async {
    final vault = MemoryPouchCredentialVault();
    final store = PouchCredentialStore(vault: vault);
    vault.values[PouchCredentialStore.keyFor('host-broken')] = '{not json';
    expect(await store.read('host-broken'), isNull);
  });
}
