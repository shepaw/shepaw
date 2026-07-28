import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/mirror_seed_service.dart';
import 'package:shepaw/storage/store_protocol.dart';

import 'test_harness.dart';

/// 升主镜像种子拷贝（方案 §6.5）。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
  });

  Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));
  String sha(Uint8List b) => crypto.sha256.convert(b).toString();

  group('ACL seed 标志', () {
    test('owner + seed 可读他端私有 attachments', () {
      const caller = 'aaaaaaaaaaaaaaaa';
      const other = 'bbbbbbbbbbbbbbbb';
      expect(
          checkStoreAcl(
            StoreFrame(op: StoreOp.meta, payload: {
              'space': StoreSpace.attachments,
              'device': other,
              'path': 'deadbeef',
            }),
            callerDeviceId: caller,
            trustLevel: TrustLevel.owner,
            loopback: false,
          ),
          StoreAcl.denyAcl);
      expect(
          checkStoreAcl(
            StoreFrame(op: StoreOp.meta, payload: {
              'space': StoreSpace.attachments,
              'device': other,
              'path': 'deadbeef',
              'seed': true,
            }),
            callerDeviceId: caller,
            trustLevel: TrustLevel.owner,
            loopback: false,
          ),
          StoreAcl.allow);
    });

    test('friend + seed 仍拒他端私有分区', () {
      expect(
          checkStoreAcl(
            StoreFrame(op: StoreOp.read, payload: {
              'space': StoreSpace.attachments,
              'device': 'bbbbbbbbbbbbbbbb',
              'path': 'x',
              'seed': true,
            }),
            callerDeviceId: 'aaaaaaaaaaaaaaaa',
            trustLevel: TrustLevel.friend,
            loopback: false,
          ),
          StoreAcl.denyUntrusted);
    });

    test('upload_id 非法形态拒绝', () {
      expect(
        () => LocalStore.checkUploadId('../escape'),
        throwsA(isA<StoreException>()),
      );
      expect(() => LocalStore.checkUploadId('u-ok-123'), returnsNormally);
    });
  });

  group('MirrorSeedService', () {
    tearDown(() {
      MirrorSeedService.instance.peerCaller = null;
    });

    test('从旧 master 差量写入本地他端目录', () async {
      final remoteRoot = await Directory.systemTemp.createTemp('seed_remote');
      final localRoot = await Directory.systemTemp.createTemp('seed_local');
      addTearDown(() async {
        await remoteRoot.delete(recursive: true);
        await localRoot.delete(recursive: true);
      });

      const oldMaster = 'aaaaaaaaaaaaaaaa';
      const peerDevice = 'bbbbbbbbbbbbbbbb';
      final remote = LocalStore(root: remoteRoot);
      final local = LocalStore(root: localRoot);
      final content = bytesOf('seed-me-please');
      final (uid, _) = await remote.writeBegin(
        deviceId: peerDevice,
        space: StoreSpace.artifacts,
        path: 't/a.txt',
        size: content.length,
        sha256: sha(content),
      );
      await remote.writeChunk(peerDevice, StoreSpace.artifacts, uid, 0, content);
      await remote.commit(peerDevice, StoreSpace.artifacts, [uid]);

      MirrorSeedService.instance.peerCaller = (peerId, frame) async {
        expect(peerId, oldMaster);
        expect(frame.payload['seed'], isTrue);
        switch (frame.op) {
          case StoreOp.list:
            final entries = await remote.list(
              frame.payload['device'] as String,
              frame.space!,
              prefix: frame.payload['path'] as String?,
            );
            return {
              'entries': [for (final e in entries) e.toJson()],
            };
          case StoreOp.read:
            final (data, size, eof) = await remote.read(
              frame.payload['device'] as String,
              frame.space!,
              frame.path!,
              frame.payload['offset'] as int? ?? 0,
              frame.payload['length'] as int? ?? LocalStore.maxReadChunk,
            );
            return {
              'data': base64Encode(data),
              'size': size,
              'eof': eof,
            };
          default:
            return {'_error': 'unsupported'};
        }
      };

      final written = await MirrorSeedService.instance.seedFromOldMaster(
        oldMasterId: oldMaster,
        deviceIds: [peerDevice, await DeviceIdentity.deviceId()],
        store: local,
      );
      expect(written, 1);
      final meta = await local.meta(peerDevice, StoreSpace.artifacts, 't/a.txt');
      expect(meta['sha256'], sha(content));
      final f = File(p.join(
          localRoot.path, peerDevice, StoreSpace.artifacts, 't', 'a.txt'));
      expect(await f.readAsBytes(), content);

      // 二次种子：已一致则跳过
      final again = await MirrorSeedService.instance.seedFromOldMaster(
        oldMasterId: oldMaster,
        deviceIds: [peerDevice],
        store: local,
      );
      expect(again, 0);
    });
  });
}
