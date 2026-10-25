import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/models/paired_peer.dart';
import 'package:shepaw/peer/models/peer_store_share.dart';
import 'package:shepaw/peer/services/peer_storage_service.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';
import 'package:shepaw/storage/store_uri_reader.dart';

import 'test_harness.dart';

class _FakeScopeTransport implements PouchScopeTransport {
  Uint8List? bytes;
  PouchFileMeta? metaEntry;
  List<StoreEntry> entries = const <StoreEntry>[];

  @override
  Future<PouchListPage> list({
    required String pouchId,
    required PouchScope scope,
    String? prefix,
    int limit = 1000,
    String? cursor,
  }) async =>
      PouchListPage(entries: entries);

  @override
  Future<Uint8List?> read({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async =>
      bytes;

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
      metaEntry;

  @override
  Future<void> write({
    required String pouchId,
    required PouchScope scope,
    required String path,
    required Uint8List bytes,
    int? expectedVersion,
  }) async {}

  @override
  Future<void> delete({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {}
}

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

    final uri = storeUriWithRef(
        StoreSpace.files, relPath);
    final back = await StoreUriReader.instance.read(uri);
    expect(utf8.decode(back), 'pouch note');
  });

  test('StoreUriReader 可读 @v1 版本引用', () async {
    final store = await StoreService.instance.localStore();
    final deviceId = await DeviceIdentity.deviceId();
    final content = Uint8List.fromList(utf8.encode('versioned note'));
    const relPath = 'docs/versioned-note.txt';
    await store.putBytes(
      deviceId: deviceId,
      space: StoreSpace.files,
      path: relPath,
      bytes: content,
    );
    final uri = storeUriWithRef(
        StoreSpace.files, relPath,
      const StoreUriRef.seq(1),
    );
    expect(uri, contains('@v1'));
    expect(utf8.decode(await StoreUriReader.instance.read(uri)),
        'versioned note');
    expect(await StoreUriReader.instance.kindOf(uri), StoreUriKind.file);
    expect(await StoreUriReader.instance.sizeOf(uri), content.length);
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

    final fileUri = storeUriWithRef(
        StoreSpace.files, relPath);
    final dirUri = storeUriWithRef(
        StoreSpace.files, 'docs');
    final spaceUri = 'pouch://${StoreSpace.files}';
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
        StoreSpace.workspaces, 'Users/edenzou/workspace/shepaw/channel/cmd',
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
        StoreSpace.workspaces, 'Users/edenzou/workspace/shepaw/channel/cmd/no-such-child',
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
        StoreSpace.workspaces, 'no/such/remote-folder',
    );
    expect(
      await StoreUriReader.instance.existingDirectoryPrefix(ghost),
      'no/such/remote-folder',
    );
  });

  test('私有分区 runtime 附件按地址读回（一袋一树，地址不带设备段）', () async {
    final store = await StoreService.instance.localStore();
    final other = await DeviceIdentity.deviceId();
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

    final uri = storeUriWithRef(StoreSpace.runtime, relPath);
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

  group('v3 袋子地址', () {
    const pouchId = 'a95b5782-4d50-45d2-83e1-8e40954d1239';
    late _FakeScopeTransport transport;

    String uriOf(String path, {String pouch = pouchId}) => PouchV2Uri(
          pouchId: pouch,
          scope: PouchScope.files.id,
          path: path,
        ).format();

    setUp(() {
      transport = _FakeScopeTransport();
      StoreService.instance.scopeStoreOverride =
          PouchScopeStore(transport: transport, pouchId: pouchId);
      StoreService.instance.currentPouchIdOverride = pouchId;
    });

    tearDown(() {
      StoreService.instance.scopeStoreOverride = null;
      StoreService.instance.currentPouchIdOverride = null;
    });

    test('sizeOf 走 hub 的 meta', () async {
      transport.metaEntry = const PouchFileMeta(
        path: 'docs/a.md',
        size: 7,
        version: 1,
        mtimeMs: 0,
      );

      expect(await StoreUriReader.instance.sizeOf(uriOf('docs/a.md')), 7);
    });

    test('sizeOf 的文件不存在时报 notFound', () async {
      expect(
        () => StoreUriReader.instance.sizeOf(uriOf('docs/missing.md')),
        throwsA(isA<StoreException>()
            .having((e) => e.code, 'code', StoreError.notFound)),
      );
    });

    test('copyTo 把 v3 文件落到目标路径', () async {
      final payload = Uint8List.fromList(utf8.encode('scope copy'));
      transport.bytes = payload;
      transport.metaEntry = PouchFileMeta(
        path: 'docs/a.md',
        size: payload.length,
        version: 1,
        mtimeMs: 0,
      );
      final dir = await Directory.systemTemp.createTemp('store_uri_v3_');
      addTearDown(() => dir.delete(recursive: true));
      final dest = File('${dir.path}/out.md');
      final progress = <(int, int)>[];

      await StoreUriReader.instance.copyTo(
        uriOf('docs/a.md'),
        dest,
        onProgress: (done, total) => progress.add((done, total)),
      );

      expect(await dest.readAsString(), 'scope copy');
      expect(progress, [(payload.length, payload.length)]);
    });

    test('copyTo 超过 maxBytes 时拒绝', () async {
      transport.bytes = Uint8List.fromList(utf8.encode('too big'));
      transport.metaEntry = const PouchFileMeta(
        path: 'docs/a.md',
        size: 7,
        version: 1,
        mtimeMs: 0,
      );
      final dir = await Directory.systemTemp.createTemp('store_uri_v3_');
      addTearDown(() => dir.delete(recursive: true));

      expect(
        () => StoreUriReader.instance
            .copyTo(uriOf('docs/a.md'), File('${dir.path}/out'), maxBytes: 3),
        throwsA(isA<StoreException>()
            .having((e) => e.code, 'code', StoreError.badOp)),
      );
    });

    test('existingDirectoryPrefix 从文件回退到目录', () async {
      transport.entries = [
        StoreEntry(path: 'docs/a.md', size: 1, sha256: '', mtimeMs: 0),
      ];

      expect(
        await StoreUriReader.instance
            .existingDirectoryPrefix(uriOf('docs/a.md')),
        'docs',
      );
      expect(
        await StoreUriReader.instance.existingDirectoryPrefix(uriOf('docs')),
        'docs',
      );
      expect(
        await StoreUriReader.instance
            .existingDirectoryPrefix(uriOf('missing/deep')),
        '',
      );
    });

    test('跨袋子地址拒绝', () async {
      expect(
        () => StoreUriReader.instance.sizeOf(
            uriOf('docs/a.md', pouch: 'b95b5782-4d50-45d2-83e1-8e40954d1239')),
        throwsA(isA<StoreException>()
            .having((e) => e.code, 'code', StoreError.crossPouchDenied)),
      );
    });
  });
}
