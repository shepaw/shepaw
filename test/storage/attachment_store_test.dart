import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/services/attachment_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/messaging/message_implicit_prompt.dart';
import 'package:shepaw/models/store_attachment_ref.dart';
import 'package:shepaw/storage/attachment_store_writer.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/snapshot_service.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

class _RecordingScopeTransport implements PouchScopeTransport {
  final writes = <({String scope, String path, Uint8List bytes})>[];

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
      null;

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
      null;

  @override
  Future<void> write({
    required String pouchId,
    required PouchScope scope,
    required String path,
    required Uint8List bytes,
    int? expectedVersion,
  }) async {
    writes.add((scope: scope.id, path: path, bytes: bytes));
  }

  @override
  Future<void> delete({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {}
}

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
    await LocalDatabaseService().database;
  });

  AttachmentService newService() =>
      AttachmentService(LocalDatabaseService());

  Future<File> tempFile(String name, List<int> bytes) async {
    final dir = await Directory.systemTemp.createTemp('att_test');
    final f = File(p.join(dir.path, name));
    await f.writeAsBytes(bytes);
    return f;
  }

  test('saveAttachment：写入 runtime/.../attachments/<hash>，metadata 以 pouch_uri 引用', () async {
    final content = Uint8List.fromList('attachment bytes'.codeUnits);
    final f = await tempFile('report.txt', content);
    final hash = crypto.sha256.convert(content).toString();
    final deviceId = await DeviceIdentity.deviceId();
    final rel =
        'a1/ch-att/attachments/$hash';
    final expectedUri = storeUriWithRef(
      StoreSpace.runtime,
      rel,
    );

    final msg = await newService().saveAttachment(
      file: f,
      channelId: 'ch-att',
      userId: 'u1',
      userName: 'U',
      agentId: 'a1',
    );
    expect(msg, isNotNull);
    expect(msg!.metadata!['pouch_uri'], expectedUri);
    expect(msg.metadata!['name'], 'report.txt');
    expect(msg.metadata!.containsKey('hash'), isFalse);
    expect(msg.metadata!.containsKey('path'), isFalse);
    expect(msg.metadata![MessageImplicitPrompt.metaKey], isNotNull);

    final root = await StoreService.instance.storeRoot();
    final blob = File(p.join(
      root.path,
      deviceId,
      StoreSpace.runtime,
      'a1',
      'ch-att',
      'attachments',
      hash,
    ));
    expect(await blob.exists(), isTrue);
    expect(await blob.readAsBytes(), content);
  });

  test('saveAttachment 双写：v3 地址记进 pouch_uri_scoped', () async {
    const pouchId = 'a95b5782-4d50-45d2-83e1-8e40954d1239';
    final transport = _RecordingScopeTransport();
    StoreService.instance.scopeStoreOverride =
        PouchScopeStore(transport: transport, pouchId: pouchId);
    StoreService.instance.currentPouchIdOverride = pouchId;
    addTearDown(() {
      StoreService.instance.scopeStoreOverride = null;
      StoreService.instance.currentPouchIdOverride = null;
    });

    final content = Uint8List.fromList('scoped mirror'.codeUnits);
    final f = await tempFile('sm.txt', content);
    final hash = crypto.sha256.convert(content).toString();
    final svc = newService();
    final msg = await svc.saveAttachment(
      file: f,
      channelId: 'ch-scope',
      userId: 'u1',
      userName: 'U',
      agentId: 'a1',
    );

    expect(msg, isNotNull);
    await svc.lastScopedMirror;
    expect(transport.writes, hasLength(1));
    expect(transport.writes.single.scope, 'agent:a1');
    expect(transport.writes.single.path, 'files/attachments/$hash');
    expect(transport.writes.single.bytes, content);

    final row = await LocalDatabaseService().getMessageById(msg!.id);
    final metadata =
        jsonDecode(row!['metadata'] as String) as Map<String, dynamic>;
    expect(
      metadata[AttachmentService.scopedUriMetaKey],
      'pouch://$pouchId/agent:a1/files/attachments/$hash',
    );
    // 这一版仍以 v2 地址为主，旧读路径不受影响。
    expect(metadata['pouch_uri'] as String, startsWith('pouch://runtime/'));
  });

  test('saveAttachment：群聊落到 group owner 而非 agent', () async {
    final content = Uint8List.fromList('group attachment'.codeUnits);
    final f = await tempFile('g.txt', content);
    final hash = crypto.sha256.convert(content).toString();
    final deviceId = await DeviceIdentity.deviceId();
    const groupId = 'group_att_owner_1';
    const sessionId = 'group_att_session_1';

    final msg = await newService().saveAttachment(
      file: f,
      channelId: sessionId,
      userId: 'u1',
      userName: 'U',
      agentId: 'agent-should-not-own',
      channelType: 'group',
      parentGroupId: groupId,
    );
    expect(msg, isNotNull);
    final uri = msg!.metadata!['pouch_uri'] as String;
    expect(
      uri,
      storeUriWithRef(
        StoreSpace.runtime,
        '$groupId/$sessionId/attachments/$hash',
      ),
    );
    expect(uri.contains('agent-should-not-own'), isFalse);

    final root = await StoreService.instance.storeRoot();
    final blob = File(p.join(
      root.path,
      deviceId,
      StoreSpace.runtime,
      groupId,
      sessionId,
      'attachments',
      hash,
    ));
    expect(await blob.exists(), isTrue);
  });

  test('hash 去重：同内容两次保存共用一个 blob 与 pouch_uri', () async {
    final content = Uint8List.fromList('dedup me'.codeUnits);
    final f1 = await tempFile('a.txt', content);
    final f2 = await tempFile('b.txt', content);
    final svc = newService();
    final m1 = await svc.saveAttachment(
        file: f1,
        channelId: 'ch-att',
        userId: 'u1',
        userName: 'U',
        agentId: 'a1');
    final m2 = await svc.saveAttachment(
        file: f2,
        channelId: 'ch-att',
        userId: 'u1',
        userName: 'U',
        agentId: 'a1');
    expect(m1!.metadata!['pouch_uri'], m2!.metadata!['pouch_uri']);
  });

  test('buildAttachmentData 按 pouch_uri 读回内容', () async {
    final content = Uint8List.fromList('read back'.codeUnits);
    final f = await tempFile('rb.txt', content);
    final svc = newService();
    final msg = await svc.saveAttachment(
        file: f,
        channelId: 'ch-att',
        userId: 'u1',
        userName: 'U',
        agentId: 'a1');
    final data = await svc.buildAttachmentData(msg!);
    expect(data, isNotNull);
    expect(data!.bytes, content);
    expect(data.fileName, 'rb.txt');
    expect(data.extraMetadata?['pouch_uri'], msg.metadata!['pouch_uri']);
  });

  test('resolveAttachmentFile：按 pouch_uri 解析', () async {
    final content = Uint8List.fromList('resolve'.codeUnits);
    final f = await tempFile('r.txt', content);
    final svc = newService();
    final msg = await svc.saveAttachment(
        file: f,
        channelId: 'ch-att',
        userId: 'u1',
        userName: 'U',
        agentId: 'a1');
    final resolved = await svc.resolveAttachmentFile(msg!.metadata!);
    expect(resolved, isNotNull);
    expect(await resolved!.readAsBytes(), content);
    expect(await svc.resolveAttachmentFile({'name': 'x'}), isNull);
  });

  test('saveAttachment pouch_uri：引用储物袋文件，不写入 chat/', () async {
    final store = await StoreService.instance.localStore();
    final deviceId = await DeviceIdentity.deviceId();
    final content = Uint8List.fromList('store ref bytes'.codeUnits);
    const relPath = 'docs/ref-report.txt';

    final (uploadId, _) = await store.writeBegin(
      deviceId: deviceId,
      space: StoreSpace.files,
      path: relPath,
      size: content.length,
      sha256: crypto.sha256.convert(content).toString(),
    );
    await store.writeChunk(
        deviceId, StoreSpace.files, uploadId, 0, content);
    await store.commit(deviceId, StoreSpace.files, [uploadId]);

    final ref = StoreAttachmentRef.fromEntry(
      deviceId: deviceId,
      space: StoreSpace.files,
      entry: StoreEntry(
        path: relPath,
        size: content.length,
        sha256: crypto.sha256.convert(content).toString(),
        mtimeMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    final localFile = await ref.resolveLocalFile();
    expect(localFile, isNotNull);

    final svc = newService();
    final msg = await svc.saveAttachment(
      file: localFile!,
      storeUri: ref.storeUri,
      displayName: ref.displayName,
      channelId: 'ch-att',
      userId: 'u1',
      userName: 'U',
      agentId: 'a1',
    );
    expect(msg, isNotNull);
    expect(msg!.metadata!['pouch_uri'], ref.storeUri);
    expect(msg.metadata!['name'], 'ref-report.txt');
    expect(msg.metadata!.containsKey('hash'), isFalse);
    expect(msg.metadata![MessageImplicitPrompt.metaKey], isNotNull);

    final root = await StoreService.instance.storeRoot();
    final hash = crypto.sha256.convert(content).toString();
    final copiedBlob = File(p.join(
      root.path,
      deviceId,
      StoreSpace.files,
      StoreSpace.chatAttachmentPrefix,
      hash,
    ));
    expect(await copiedBlob.exists(), isFalse);

    final data = await svc.buildAttachmentData(msg);
    expect(data, isNotNull);
    expect(data!.bytes, content);
    expect(data.extraMetadata?['pouch_uri'], ref.storeUri);

    final resolved = await svc.resolveAttachmentFile(msg.metadata!);
    expect(resolved, isNotNull);
    expect(await resolved!.readAsBytes(), content);
    expect(msg.content, contains(ref.storeUri));
  });

  test('快照 manifest.attachments 引用 runtime/.../attachments/<hash>', () async {
    final content = Uint8List.fromList('in snapshot manifest'.codeUnits);
    final f = await tempFile('s.txt', content);
    final hash = crypto.sha256.convert(content).toString();
    await newService().saveAttachment(
        file: f,
        channelId: 'ch-att',
        userId: 'u1',
        userName: 'U',
        agentId: 'a1');

    final snap =
        await SnapshotService.instance.createSnapshot(password: 'm5-pw');
    expect(
      snap.manifest.attachments,
      contains('${StoreSpace.runtime}/a1/ch-att/attachments/$hash'),
    );
    expect(snap.manifest.fileHashes.keys,
        containsAll(['db.sqlite.enc', 'identity.enc']));
    expect(snap.manifest.fileHashes.length, 2);
  });

  test('AttachmentStoreWriter：peer 入站频道落到 runtime/<A>/<peer__…>/attachments',
      () async {
    final content = Uint8List.fromList('peer inbound bytes'.codeUnits);
    final hash = crypto.sha256.convert(content).toString();
    final deviceId = await DeviceIdentity.deviceId();
    const agentId = 'agent-a';
    const channelId = 'peer__p1__agent-a__s_sess1';
    final uri = await AttachmentStoreWriter.storeBytes(
      content,
      ownerId: agentId,
      channelId: channelId,
    );
    final rel = '$agentId/$channelId/attachments/$hash';
    expect(uri, storeUriWithRef(StoreSpace.runtime, rel));
    final root = await StoreService.instance.storeRoot();
    final blob = File(p.join(
      root.path,
      deviceId,
      StoreSpace.runtime,
      agentId,
      channelId,
      'attachments',
      hash,
    ));
    expect(await blob.exists(), isTrue);
    expect(await blob.readAsBytes(), content);
  });
}
