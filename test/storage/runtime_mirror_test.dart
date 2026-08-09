import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/runtime_mirror_service.dart';
import 'package:shepaw/storage/runtime_paths.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  test('mirrorSoul / ensureRuntimeScaffold 写入 runtime', () async {
    final mirror = RuntimeMirrorService.instance;
    mirror.debounce = Duration.zero;
    await mirror.mirrorSoul('agent-mirror', 'I am a test soul.');
    await mirror.ensureRuntimeScaffold('agent-mirror');

    final deviceId = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    final soulMeta =
        await store.meta(deviceId, StoreSpace.runtime, RuntimePaths.soulMd('agent-mirror'));
    expect(soulMeta['size'] as int, greaterThan(0));

    final (bytes, _, _) = await store.read(
      deviceId,
      StoreSpace.runtime,
      RuntimePaths.soulMd('agent-mirror'),
      0,
      1 << 16,
    );
    expect(utf8.decode(bytes), contains('I am a test soul.'));

    final manifestMeta = await store.meta(
      deviceId,
      StoreSpace.runtime,
      RuntimePaths.contextManifest('agent-mirror'),
    );
    expect(manifestMeta['size'] as int, greaterThan(0));
  });

  test('writeWorkspaceFile 本机落盘', () async {
    final deviceId = await DeviceIdentity.deviceId();
    final uri = await StoreService.instance.writeWorkspaceFile(
      homeDeviceId: deviceId,
      relPath: 'ws-demo/hello.txt',
      content: Uint8List.fromList(utf8.encode('hello workspace')),
    );
    expect(uri, contains('store://workspaces/$deviceId/ws-demo/hello.txt'));
    final store = await StoreService.instance.localStore();
    final (bytes, _, _) = await store.read(
      deviceId,
      StoreSpace.workspaces,
      'ws-demo/hello.txt',
      0,
      1024,
    );
    expect(utf8.decode(bytes), 'hello workspace');
  });
}
