import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/models/paired_peer.dart';
import 'package:shepaw/peer/models/peer_store_share.dart';
import 'package:shepaw/peer/services/peer_storage_service.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';
import 'package:shepaw/storage/store_uri_reader.dart';

import 'test_harness.dart';

void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  test('StoreUriReader 可读 files 空间 URI', () async {
    final store = await StoreService.instance.localStore();
    final deviceId = await DeviceIdentity.deviceId();
    final content = Uint8List.fromList(utf8.encode('pouch note'));
    const relPath = 'docs/pouch-note.txt';
    final (uploadId, _) = await store.writeBegin(
      deviceId: deviceId,
      space: StoreSpace.files,
      path: relPath,
      size: content.length,
      sha256: crypto.sha256.convert(content).toString(),
    );
    await store.writeChunk(deviceId, StoreSpace.files, uploadId, 0, content);
    await store.commit(deviceId, StoreSpace.files, [uploadId]);

    final uri = storeUriWithRef(StoreSpace.files, deviceId, relPath);
    final back = await StoreUriReader.instance.read(uri);
    expect(utf8.decode(back), 'pouch note');
  });

  test('StoreUriReader.kindOf 区分文件与目录', () async {
    final store = await StoreService.instance.localStore();
    final deviceId = await DeviceIdentity.deviceId();
    final content = Uint8List.fromList(utf8.encode('kind check'));
    const relPath = 'docs/kind-check.txt';
    final (uploadId, _) = await store.writeBegin(
      deviceId: deviceId,
      space: StoreSpace.files,
      path: relPath,
      size: content.length,
      sha256: crypto.sha256.convert(content).toString(),
    );
    await store.writeChunk(deviceId, StoreSpace.files, uploadId, 0, content);
    await store.commit(deviceId, StoreSpace.files, [uploadId]);

    final fileUri = storeUriWithRef(StoreSpace.files, deviceId, relPath);
    final dirUri = storeUriWithRef(StoreSpace.files, deviceId, 'docs');
    final spaceUri = 'store://${StoreSpace.files}/$deviceId';
    expect(await StoreUriReader.instance.kindOf(fileUri), StoreUriKind.file);
    expect(
        await StoreUriReader.instance.kindOf(dirUri), StoreUriKind.directory);
    expect(
        await StoreUriReader.instance.kindOf(spaceUri), StoreUriKind.directory);

    const wsRel = 'Users/edenzou/workspace/shepaw/channel/cmd/note.txt';
    final (wsId, _) = await store.writeBegin(
      deviceId: deviceId,
      space: StoreSpace.workspaces,
      path: wsRel,
      size: content.length,
      sha256: crypto.sha256.convert(content).toString(),
    );
    await store.writeChunk(deviceId, StoreSpace.workspaces, wsId, 0, content);
    await store.commit(deviceId, StoreSpace.workspaces, [wsId]);
    final folderUri = storeUriWithRef(
      StoreSpace.workspaces,
      deviceId,
      'Users/edenzou/workspace/shepaw/channel/cmd',
    );
    expect(
      await StoreUriReader.instance.kindOf(folderUri),
      StoreUriKind.directory,
    );
    expect(
      await StoreUriReader.instance.existingDirectoryPrefix(folderUri),
      'Users/edenzou/workspace/shepaw/channel/cmd',
    );
    final missingLeaf = storeUriWithRef(
      StoreSpace.workspaces,
      deviceId,
      'Users/edenzou/workspace/shepaw/channel/cmd/no-such-child',
    );
    expect(
      await StoreUriReader.instance.existingDirectoryPrefix(missingLeaf),
      'Users/edenzou/workspace/shepaw/channel/cmd/no-such-child',
    );
    expect(
      await StoreUriReader.instance.existingDirectoryPrefix(fileUri),
      'docs',
    );
    final ghost = storeUriWithRef(
      StoreSpace.workspaces,
      deviceId,
      'no/such/remote-folder',
    );
    expect(
      await StoreUriReader.instance.existingDirectoryPrefix(ghost),
      'no/such/remote-folder',
    );
  });

  test('StoreUriReader 拒绝他端私有分区', () async {
    const other = 'bbbbbbbbbbbbbbbb';
    final uri = storeUriWithRef(StoreSpace.attachments, other, 'deadbeef');
    expect(
      () => StoreUriReader.instance.read(uri),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('他端私有分区本机缓存命中（peer 隧道附件共用 URI）', () async {
    final store = await StoreService.instance.localStore();
    const other = 'dddddddddddddddd';
    final bytes =
        Uint8List.fromList(utf8.encode('peer cached attachment bytes'));
    final hash = crypto.sha256.convert(bytes).toString();
    final relPath = 'agent_1/peer__peer_1__agent_1/attachments/$hash';

    final (uploadId, _) = await store.writeBegin(
      deviceId: other,
      space: StoreSpace.runtime,
      path: relPath,
      size: bytes.length,
      sha256: hash,
    );
    await store.writeChunk(other, StoreSpace.runtime, uploadId, 0, bytes);
    await store.commit(other, StoreSpace.runtime, [uploadId]);

    final uri = storeUriWithRef(StoreSpace.runtime, other, relPath);
    expect(await StoreUriReader.instance.kindOf(uri), StoreUriKind.file);
    expect(await StoreUriReader.instance.sizeOf(uri), bytes.length);
    expect(
      utf8.decode(await StoreUriReader.instance.read(uri)),
      'peer cached attachment bytes',
    );

    final dest = File('${tmp.path}/peer_uri_copy.bin');
    await StoreUriReader.instance.copyTo(uri, dest);
    expect(
      utf8.decode(await dest.readAsBytes()),
      'peer cached attachment bytes',
    );
  });

  test('他端私有分区无本机缓存仍拒绝（不误放行）', () async {
    const other = 'eeeeeeeeeeeeeeee';
    final uri = storeUriWithRef(
      StoreSpace.runtime,
      other,
      'agent_1/channel_1/attachments/'
      '1111111111111111111111111111111111111111111111111111111111111111',
    );
    expect(
      () => StoreUriReader.instance.read(uri),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('入站分享放行判定：runtime 附件/产物放行，soul/会话拒绝', () async {
    const other = 'ffffffffffffffff';
    final peerStorage = PeerStorageService();
    await peerStorage.savePeer(PairedPeer(
      id: 'peer-runtime-1',
      deviceName: 'runtime-peer',
      deviceId: other,
      publicKey: Uint8List.fromList([1, 2, 3]),
      fingerprint: other,
      pairedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await peerStorage.replaceInboundStoreShares(
      'peer-runtime-1',
      deviceId: other,
      entries: const [
        PeerStoreShareEntry(space: StoreSpace.runtime, path: 'agent_1'),
      ],
    );

    const hash =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    expect(
      await StoreUriReader.instance.inboundShareAllows(
        space: StoreSpace.runtime,
        device: other,
        path: 'agent_1/ch_1/attachments/$hash',
      ),
      isTrue,
    );
    expect(
      await StoreUriReader.instance.inboundShareAllows(
        space: StoreSpace.runtime,
        device: other,
        path: 'agent_1/ch_1/artifacts/task_1/out.txt',
      ),
      isTrue,
    );
    // 敏感清单快速失败
    expect(
      await StoreUriReader.instance.inboundShareAllows(
        space: StoreSpace.runtime,
        device: other,
        path: 'agent_1/soul.md',
      ),
      isFalse,
    );
    expect(
      await StoreUriReader.instance.inboundShareAllows(
        space: StoreSpace.runtime,
        device: other,
        path: 'agent_1/ch_1/sessions/session.json',
      ),
      isFalse,
    );
    // 无配对 peer 的设备仍拒绝
    expect(
      await StoreUriReader.instance.inboundShareAllows(
        space: StoreSpace.runtime,
        device: 'eeeeeeeeeeeeeeee',
        path: 'agent_1/ch_1/attachments/$hash',
      ),
      isFalse,
    );
  });
}
