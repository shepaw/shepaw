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

  /// 轮询等 manifest 的 channels 里出现 [ids]，返回最后一次读到的内容。
  ///
  /// 全量并行跑（多文件争 CPU）时固定 sleep 不够，会偶发地只读到部分会话。
  Future<Map<String, dynamic>> waitForManifestChannels(
    String owner,
    List<String> ids,
  ) async {
    final deviceId = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    var channels = <String, dynamic>{};
    for (var i = 0; i < 100; i++) {
      try {
        final (bytes, _, _) = await store.read(
          deviceId,
          StoreSpace.runtime,
          RuntimePaths.contextManifest(owner),
          0,
          1 << 16,
        );
        final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        channels = (json['channels'] as Map?)?.cast<String, dynamic>() ?? {};
        if (ids.every(channels.containsKey)) break;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return channels;
  }

  /// 轮询等 runtime 空间里出现 [rel]。
  Future<Map<String, dynamic>?> waitForRuntimeFile(
    String deviceId,
    String rel,
  ) async {
    final store = await StoreService.instance.localStore();
    for (var i = 0; i < 100; i++) {
      try {
        return await store.meta(deviceId, StoreSpace.runtime, rel);
      } on StoreException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    return null;
  }

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
    expect(uri, contains('pouch://workspaces/$deviceId/ws-demo/hello.txt'));
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

  test('同一 owner 的多个会话都留在 manifest 的 channels 里', () async {
    final mirror = RuntimeMirrorService.instance;
    mirror.debounce = Duration.zero;
    const owner = 'agent-multi-channel';
    const first = 'dm_a';
    const second = 'dm_b';

    // 两次镜像必须串行：并发写同一个 manifest 会互相覆盖（后写的读到的
    // 是旧内容）。固定 sleep 在全量并行跑时不够，改成等第一次真的落盘。
    mirror.scheduleSessionMirror(ownerId: owner, channelId: first);
    await waitForManifestChannels(owner, [first]);
    mirror.scheduleSessionMirror(ownerId: owner, channelId: second);
    final channels = await waitForManifestChannels(owner, [first, second]);

    // 第二次镜像曾经会先清空 manifest，导致只剩最后这一个会话。
    expect(channels.keys, containsAll([first, second]));
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

  test('debounce 窗口内的连续镜像合并成一次，flushPendingSessions 立即落盘',
      () async {
    final mirror = RuntimeMirrorService.instance;
    // 窗口远大于本测试的等待时间：期间不应该有任何写。
    mirror.debounce = const Duration(seconds: 30);
    addTearDown(() => mirror.debounce = Duration.zero);

    const owner = 'agent-flush-coalesce';
    const channel = 'dm_flush';
    final deviceId = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    final rel = RuntimePaths.sessionJson(owner, channel);

    for (var i = 0; i < 10; i++) {
      mirror.scheduleSessionMirror(ownerId: owner, channelId: channel);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      () => store.meta(deviceId, StoreSpace.runtime, rel),
      throwsA(isA<StoreException>()),
    );

    await mirror.flushPendingSessions();
    final meta = await store.meta(deviceId, StoreSpace.runtime, rel);
    expect(meta['size'] as int, greaterThan(0));
  });

  test('持续写入时靠 maxStaleness 兜底落盘', () async {
    final mirror = RuntimeMirrorService.instance;
    mirror.debounce = const Duration(seconds: 30);
    mirror.maxStaleness = const Duration(milliseconds: 200);
    addTearDown(() {
      mirror.debounce = Duration.zero;
      mirror.maxStaleness = const Duration(seconds: 10);
    });

    const owner = 'agent-staleness';
    const channel = 'dm_staleness';
    final deviceId = await DeviceIdentity.deviceId();
    final rel = RuntimePaths.sessionJson(owner, channel);

    // 连续写（模拟流式 flush）：空闲 debounce 永远等不到窗口。
    for (var i = 0; i < 6; i++) {
      mirror.scheduleSessionMirror(ownerId: owner, channelId: channel);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }

    // 镜像写是异步的，轮询等它落盘（固定 sleep 在全量并行跑时不够）。
    final meta = await waitForRuntimeFile(deviceId, rel);
    expect(meta, isNotNull);
    expect(meta!['size'] as int, greaterThan(0));
  });

  test('session.json 不带缩进', () async {
    final mirror = RuntimeMirrorService.instance;
    mirror.debounce = Duration.zero;
    const owner = 'agent-no-indent';
    const channel = 'dm_indent';

    mirror.scheduleSessionMirror(ownerId: owner, channelId: channel);
    await mirror.flushPendingSessions();

    final deviceId = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    final (bytes, _, _) = await store.read(
      deviceId,
      StoreSpace.runtime,
      RuntimePaths.sessionJson(owner, channel),
      0,
      1 << 16,
    );
    final body = utf8.decode(bytes);
    jsonDecode(body); // 仍是合法 JSON
    expect(body.contains('\n  "'), isFalse);
  });

  test('invalidateMirrorRoute 后重新解析落盘路由', () async {
    final mirror = RuntimeMirrorService.instance;
    mirror.debounce = Duration.zero;
    const owner = 'agent-route-cache';
    const channel = 'dm_route';

    mirror.scheduleSessionMirror(ownerId: owner, channelId: channel);
    await mirror.flushPendingSessions();
    mirror.invalidateMirrorRoute();

    // 清空缓存不应影响后续镜像：重新解析后仍能落盘。
    mirror.scheduleSessionMirror(ownerId: owner, channelId: channel);
    await mirror.flushPendingSessions();

    final deviceId = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    final meta = await store.meta(
      deviceId,
      StoreSpace.runtime,
      RuntimePaths.sessionJson(owner, channel),
    );
    expect(meta['size'] as int, greaterThan(0));
  });
}
