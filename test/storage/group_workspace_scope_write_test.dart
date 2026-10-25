import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/group_workspace_scopes.dart';
import 'package:shepaw/storage/group_workspace_service.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

class _MemoryScopeTransport implements PouchScopeTransport {
  final writes = <({String scope, String path, Uint8List bytes})>[];
  final files = <String, Uint8List>{};

  String _key(PouchScope scope, String path) => '${scope.id}/$path';

  @override
  Future<PouchListPage> list({
    required String pouchId,
    required PouchScope scope,
    String? prefix,
    int limit = 1000,
    String? cursor,
  }) async =>
      const PouchListPage(entries: <StoreEntry>[]);

  @override
  Future<Uint8List?> read({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async =>
      files[_key(scope, path)];

  @override
  Future<List<String>> scopes({
    required String pouchId,
    required String prefix,
  }) async =>
      const <String>[];

  @override
  Future<PouchFileMeta?> meta({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async =>
      files.containsKey(_key(scope, path))
          ? PouchFileMeta(path: path, size: 1, version: 1, mtimeMs: 0)
          : null;

  @override
  Future<void> write({
    required String pouchId,
    required PouchScope scope,
    required String path,
    required Uint8List bytes,
    int? expectedVersion,
  }) async {
    writes.add((scope: scope.id, path: path, bytes: bytes));
    files[_key(scope, path)] = bytes;
  }

  @override
  Future<void> delete({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {
    files.remove(_key(scope, path));
  }
}

void main() {
  const pouchId = 'a95b5782-4d50-45d2-83e1-8e40954d1239';
  const groupId = 'group_scope1';

  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  group('GroupWorkspaceScopes', () {
    test('shared/<rel> 挂到 group:<gid>:shared', () {
      final target = GroupWorkspaceScopes.map('$groupId/shared/memory/latest.md');
      expect(target, isNotNull);
      expect(target!.scope, PouchScope.groupShared(groupId));
      expect(target.path, 'memory/latest.md');
    });

    test('group-workspace.json 与 members/ 暂不映射（仍是 v2）', () {
      expect(GroupWorkspaceScopes.map('$groupId/group-workspace.json'), isNull);
      expect(GroupWorkspaceScopes.map('$groupId/members/a1/x.md'), isNull);
      expect(GroupWorkspaceScopes.map('$groupId/shared'), isNull);
    });

    test('群 id 不合法时不映射', () {
      expect(GroupWorkspaceScopes.map('bad id/shared/a.md'), isNull);
    });
  });

  group('GroupWorkspaceService 写共享面', () {
    late _MemoryScopeTransport transport;

    setUp(() async {
      transport = _MemoryScopeTransport();
      StoreService.instance.scopeStoreOverride =
          PouchScopeStore(transport: transport, pouchId: pouchId);
      StoreService.instance.currentPouchIdOverride = pouchId;
      await GroupWorkspaceService.instance.ensureGroupWorkspace(
        groupId: groupId,
        members: [(agentId: 'agent-a', role: 'admin')],
      );
    });

    tearDown(() {
      StoreService.instance.scopeStoreOverride = null;
      StoreService.instance.currentPouchIdOverride = null;
    });

    test('writeSharedMemory 落到 group:<gid>:shared/memory', () async {
      final uri = await GroupWorkspaceService.instance.writeSharedMemory(
        groupId: groupId,
        sessionId: 's1',
        content: 'round done',
      );

      expect(transport.writes.map((w) => '${w.scope}/${w.path}'), [
        'group:$groupId:shared/memory/s1.md',
        'group:$groupId:shared/memory/latest.md',
      ]);
      expect(uri, 'pouch://$pouchId/group:$groupId:shared/memory/latest.md');
      expect(
        GroupWorkspaceService.instance.readSharedMemoryLatest(groupId),
        completion('round done'),
      );
    });

    test('writeSharedHandoff 返回袋子地址', () async {
      final uris = await GroupWorkspaceService.instance.writeSharedHandoff(
        groupId: groupId,
        handoffId: 'h1',
        jsonContent: '{"a":1}',
        markdownContent: '# 交接',
      );

      expect(uris, isNotNull);
      expect(
        uris!.jsonUri,
        'pouch://$pouchId/group:$groupId:shared/handoffs/h1.json',
      );
      expect(
        uris.mdUri,
        'pouch://$pouchId/group:$groupId:shared/handoffs/h1.md',
      );
    });

    test('taskFileUri 有袋子时给 v3 地址', () async {
      final uri = await GroupWorkspaceService.instance.taskFileUri(
        groupId: groupId,
        relPath: GroupWorkspaceService.instance
            .taskJsonRelPath(groupId, 'orch1'),
      );
      expect(uri, contains('group:$groupId:shared/tasks/orch1/task.json'));
      expect(uri, startsWith('pouch://$pouchId/'));
    });

    test('读共享文件：袋子里没有时回退 v2', () async {
      // 先按 v2 写一份（模拟切换前的存量）。
      StoreService.instance.scopeStoreOverride = null;
      final rel = '${GroupWorkspaceService.instance.workspaceRoot(groupId)}'
          '/shared/memory/latest.md';
      await StoreService.instance.writeWorkspaceFile(
        homeDeviceId: await DeviceIdentity.deviceId(),
        relPath: rel,
        content: Uint8List.fromList(utf8.encode('from v2')),
      );

      StoreService.instance.scopeStoreOverride =
          PouchScopeStore(transport: transport, pouchId: pouchId);
      expect(
        await StoreService.instance.readScope(
          PouchScope.groupShared(groupId),
          'memory/latest.md',
        ),
        isNull,
        reason: '袋子里还没有这份文件',
      );
      expect(
        await GroupWorkspaceService.instance.readSharedMemoryLatest(groupId),
        'from v2',
      );
    });
  });
}
