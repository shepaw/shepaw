import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/services/attachment_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/messaging/message_implicit_prompt.dart';
import 'package:shepaw/models/store_attachment_ref.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/snapshot_service.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

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

  test('saveAttachment：写入 files/chat/<hash>，metadata 以 store_uri 引用', () async {
    final content = Uint8List.fromList('attachment bytes'.codeUnits);
    final f = await tempFile('report.txt', content);
    final hash = crypto.sha256.convert(content).toString();
    final deviceId = await DeviceIdentity.deviceId();
    final expectedUri = storeUriWithRef(
      StoreSpace.files,
      deviceId,
      '${StoreSpace.chatAttachmentPrefix}/$hash',
    );

    final msg = await newService().saveAttachment(
      file: f,
      channelId: 'ch-att',
      userId: 'u1',
      userName: 'U',
      agentId: 'a1',
    );
    expect(msg, isNotNull);
    expect(msg!.metadata!['store_uri'], expectedUri);
    expect(msg.metadata!['name'], 'report.txt');
    expect(msg.metadata!.containsKey('hash'), isFalse);
    expect(msg.metadata!.containsKey('path'), isFalse);
    expect(msg.metadata![MessageImplicitPrompt.metaKey], isNotNull);

    final root = await StoreService.instance.storeRoot();
    final blob = File(p.join(
      root.path,
      deviceId,
      StoreSpace.files,
      StoreSpace.chatAttachmentPrefix,
      hash,
    ));
    expect(await blob.exists(), isTrue);
    expect(await blob.readAsBytes(), content);
  });

  test('hash 去重：同内容两次保存共用一个 blob 与 store_uri', () async {
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
    expect(m1!.metadata!['store_uri'], m2!.metadata!['store_uri']);
  });

  test('buildAttachmentData 按 store_uri 读回内容', () async {
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
    expect(data.extraMetadata?['store_uri'], msg.metadata!['store_uri']);
  });

  test('resolveAttachmentFile：按 store_uri 解析', () async {
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

  test('saveAttachment store_uri：引用储物袋文件，不写入 chat/', () async {
    final store = await StoreService.instance.localStore();
    final deviceId = await DeviceIdentity.deviceId();
    final content = Uint8List.fromList('store ref bytes'.codeUnits);
    final relPath = 'docs/ref-report.txt';

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
    expect(msg!.metadata!['store_uri'], ref.storeUri);
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
    expect(data.extraMetadata?['store_uri'], ref.storeUri);

    final resolved = await svc.resolveAttachmentFile(msg.metadata!);
    expect(resolved, isNotNull);
    expect(await resolved!.readAsBytes(), content);
    expect(msg.content, contains(ref.storeUri));
  });

  test('快照 manifest.attachments 引用 files/chat/<hash>', () async {
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
      contains('${StoreSpace.chatAttachmentPrefix}/$hash'),
    );
    expect(snap.manifest.fileHashes.keys,
        containsAll(['db.sqlite.enc', 'identity.enc']));
    expect(snap.manifest.fileHashes.length, 2);
  });
}
