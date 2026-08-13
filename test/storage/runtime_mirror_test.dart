import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/local_store.dart';
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

  test('群 runtime scaffold 不写 soul.md', () async {
    final mirror = RuntimeMirrorService.instance;
    await mirror.ensureRuntimeScaffold(
      'group-no-soul',
      includePersonaMirror: false,
    );
    final deviceId = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    expect(
      () => store.meta(
        deviceId,
        StoreSpace.runtime,
        RuntimePaths.soulMd('group-no-soul'),
      ),
      throwsA(isA<StoreException>()),
    );
    final (bytes, _, _) = await store.read(
      deviceId,
      StoreSpace.runtime,
      RuntimePaths.contextManifest('group-no-soul'),
      0,
      1 << 16,
    );
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    expect(json.containsKey('soul_uri'), isFalse);
    expect(json.containsKey('memory_uri'), isFalse);
    expect(json['owner_id'], 'group-no-soul');
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

  test('peer session mirror 写入对端 device 的 runtime session.json', () async {
    final mirror = RuntimeMirrorService.instance;
    mirror.debounce = Duration.zero;
    const hostDevice = 'aabbccddeeff0011';
    const owner = 'remote-agent-a';
    const hostChannel = 'peer__pair1__remote-agent-a__s_dm_local';
    const localChannel = 'dm_local';

    mirror.scheduleSessionMirror(
      ownerId: owner,
      channelId: hostChannel,
      deviceId: hostDevice,
      messagesChannelId: localChannel,
    );
    // debounce=0 still schedules via Timer; wait for write.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final store = await StoreService.instance.localStore();
    final rel = RuntimePaths.sessionJson(owner, hostChannel);
    final meta = await store.meta(hostDevice, StoreSpace.runtime, rel);
    expect(meta['size'] as int, greaterThan(0));
    final (bytes, _, _) = await store.read(
      hostDevice,
      StoreSpace.runtime,
      rel,
      0,
      1 << 16,
    );
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final sessionMeta = json['meta'] as Map<String, dynamic>;
    expect(sessionMeta['source_device'], hostDevice);
    expect(sessionMeta['placement'], 'local_fallback');
    expect(sessionMeta['local_channel_id'], localChannel);
    expect(sessionMeta['channel_id'], hostChannel);
  });
}
