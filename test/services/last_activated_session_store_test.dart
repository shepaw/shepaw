import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/services/session/last_activated_session_store.dart';

/// 指针写入点全是 `unawaited`（切换会话不能被平台通道拖住），但紧随其后的
/// 会话列表补刷必须看到这次点选。这里覆盖进程内立即可见、写盘顺序、删除清理。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late LastActivatedSessionStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = LastActivatedSessionStore(prefs: prefs);
  });

  LastActivatedSessionStore other() =>
      LastActivatedSessionStore(prefs: prefs);

  test('remember 后同一实例立刻读得到，且会落盘给新实例', () async {
    const key = 'agent:a1';
    // 故意不 await：模拟 chat_screen / navigation 里的 unawaited 调用。
    unawaited(store.remember(key, 'ch-a'));
    expect(await store.read(key), 'ch-a');

    // 等写盘完成后，跨实例也应看得到。
    await store.remember(key, 'ch-a');
    expect(await other().read(key), 'ch-a');
  });

  test('连续点选以最后一次为准', () async {
    const key = 'agent:a1';
    await Future.wait([
      store.remember(key, 'ch-old'),
      store.remember(key, 'ch-new'),
    ]);
    expect(await other().read(key), 'ch-new');
  });

  test('forgetChannel 会取消还在路上的写入，不留回魂指针', () async {
    const key = 'agent:a1';
    final write = store.remember(key, 'ch-deleted');
    await store.forgetChannel('ch-deleted');
    await write;

    expect(await store.read(key), isNull);
    expect(await other().read(key), isNull);
  });

  test('forgetChannel 等移除落地，且只清掉指向该会话的 key', () async {
    const agentA = 'agent:a';
    const agentB = 'agent:b';
    await store.remember(agentA, 'ch-gone');
    await store.remember(agentB, 'ch-kept');

    // 生产里 store 是 getIt 单例，读写都走同一个实例；这里也用同一个。
    await store.forgetChannel('ch-gone');

    expect(await store.read(agentA), isNull);
    expect(await store.read(agentB), 'ch-kept');
    expect(await other().read(agentA), isNull);
    expect(await other().read(agentB), 'ch-kept');
  });

  test('forgetChannel 立刻立墓碑，不会读回盘上还没删掉的旧指针', () async {
    const key = 'agent:a1';
    await store.remember(key, 'ch-gone');

    final removal = store.forgetChannel('ch-gone'); // 故意不 await
    expect(await store.read(key), isNull);
    await removal;
    expect(await other().read(key), isNull);
  });

  test('删会话期间又点开新会话，旧 remove 不抹掉新指针', () async {
    const key = 'agent:a1';
    await store.remember(key, 'ch-old');

    final removal = store.forgetChannel('ch-old');
    await store.remember(key, 'ch-new');
    await removal;

    expect(await store.read(key), 'ch-new');
    expect(await other().read(key), 'ch-new');
  });

  test('空 key / 空频道不写盘', () async {
    await store.remember('', 'ch-a');
    await store.remember('agent:a1', '');
    expect(await store.readAll(['', 'agent:a1']), isEmpty);
  });

  test('生产路径不注入 prefs 时走插件单例，跨实例可读', () async {
    SharedPreferences.setMockInitialValues({});
    const key = 'agent:no-injected-prefs';
    final production = LastActivatedSessionStore();
    await production.remember(key, 'ch-prod');

    expect(await LastActivatedSessionStore().read(key), 'ch-prod');
  });
}
