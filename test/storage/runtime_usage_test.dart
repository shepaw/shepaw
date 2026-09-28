import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

/// runtime 子类用量（`docs/runtime_lifecycle_decision.md` 第 1 步）。
///
/// 分类是后续保留策略的前提：会话 / 附件可以有 TTL，产物不该自动过期。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  Future<void> put(LocalStore store, String device, String rel, String text) =>
      store.putBytes(
        deviceId: device,
        space: StoreSpace.runtime,
        path: rel,
        bytes: Uint8List.fromList(utf8.encode(text)),
      );

  test('按 sessions / attachments / artifacts / mirrors 分类统计', () async {
    final store = await StoreService.instance.localStore();
    final device = await DeviceIdentity.deviceId();

    await put(store, device, 'agent-u/ch/sessions/session.json', 's' * 10);
    await put(store, device, 'agent-u/ch/sessions/archive-1.json', 'a' * 20);
    await put(store, device, 'agent-u/ch/attachments/' + 'b' * 64, 'x' * 30);
    await put(store, device, 'agent-u/ch/artifacts/t/report.md', 'r' * 40);
    await put(
        store, device, 'agent-u/ch/artifacts/t/report.md.meta.json', 'm' * 5);
    await put(store, device, 'agent-u/soul.md', 'o' * 50);
    await put(store, device, 'agent-u/context.manifest.json', 'c' * 7);

    final usage = await store.runtimeUsageBreakdown(device);
    expect(usage['sessions'], 30);
    expect(usage['attachments'], 30);
    expect(usage['artifacts'], 45); // 产物 + 元数据 sidecar
    expect(usage['mirrors'], 50);
    expect(usage['other'], 7); // manifest
    expect(usage['versions'], isNotNull);
  });

  test('StoreService 暴露同一份统计', () async {
    final device = await DeviceIdentity.deviceId();
    final usage = await StoreService.instance.runtimeUsageBreakdown(device);
    expect(usage.keys,
        containsAll(['sessions', 'attachments', 'artifacts', 'mirrors']));
  });
}
