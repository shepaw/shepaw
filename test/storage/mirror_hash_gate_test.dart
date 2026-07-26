import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/mirror_hash_gate.dart';
import 'package:shepaw/storage/store_protocol.dart';

import 'test_harness.dart';

/// 升主内容哈希门闩（方案 §6.5）。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
  });

  Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));
  String sha(Uint8List b) => crypto.sha256.convert(b).toString();

  Future<void> putFile(
    LocalStore store,
    String deviceId,
    String space,
    String path,
    Uint8List content,
  ) async {
    final (uid, _) = await store.writeBegin(
      deviceId: deviceId,
      space: space,
      path: path,
      size: content.length,
      sha256: sha(content),
    );
    await store.writeChunk(deviceId, space, uid, 0, content);
    await store.commit(deviceId, space, [uid]);
  }

  group('MirrorHashGate', () {
    tearDown(() {
      MirrorHashGate.instance.peerCaller = null;
    });

    test('两边一致 → ok；缺本地文件 → missing_local', () async {
      final remoteRoot = await Directory.systemTemp.createTemp('gate_remote');
      final localRoot = await Directory.systemTemp.createTemp('gate_local');
      addTearDown(() async {
        await remoteRoot.delete(recursive: true);
        await localRoot.delete(recursive: true);
      });

      const oldMaster = 'aaaaaaaaaaaaaaaa';
      const peerDevice = 'bbbbbbbbbbbbbbbb';
      final remote = LocalStore(root: remoteRoot);
      final local = LocalStore(root: localRoot);
      final content = bytesOf('gate-payload');
      await putFile(
          remote, peerDevice, StoreSpace.artifacts, 't/a.txt', content);

      MirrorHashGate.instance.peerCaller = (peerId, frame) async {
        expect(peerId, oldMaster);
        expect(frame.payload['seed'], isTrue);
        final entries = await remote.list(
          frame.payload['device'] as String,
          frame.space!,
          prefix: frame.payload['path'] as String?,
          limit: frame.payload['limit'] as int? ?? MirrorHashGate.listLimit,
        );
        return {
          'entries': [for (final e in entries) e.toJson()],
        };
      };

      final missing = await MirrorHashGate.instance.verify(
        oldMasterId: oldMaster,
        deviceIds: [peerDevice],
        store: local,
      );
      expect(missing.ran, isTrue);
      expect(missing.ok, isFalse);
      expect(missing.mismatches, isNotEmpty);
      expect(missing.mismatches.first.kind, 'missing_local');

      await putFile(
          local, peerDevice, StoreSpace.artifacts, 't/a.txt', content);
      final ok = await MirrorHashGate.instance.verify(
        oldMasterId: oldMaster,
        deviceIds: [peerDevice],
        store: local,
      );
      expect(ok.ok, isTrue);
      expect(ok.devices.single.matched, isTrue);
    });

    test('hash 不同 → hash_mismatch', () async {
      final remoteRoot = await Directory.systemTemp.createTemp('gate_remote2');
      final localRoot = await Directory.systemTemp.createTemp('gate_local2');
      addTearDown(() async {
        await remoteRoot.delete(recursive: true);
        await localRoot.delete(recursive: true);
      });

      const oldMaster = 'aaaaaaaaaaaaaaaa';
      const peerDevice = 'bbbbbbbbbbbbbbbb';
      final remote = LocalStore(root: remoteRoot);
      final local = LocalStore(root: localRoot);
      await putFile(remote, peerDevice, StoreSpace.artifacts, 'x.txt',
          bytesOf('remote'));
      await putFile(
          local, peerDevice, StoreSpace.artifacts, 'x.txt', bytesOf('local'));

      MirrorHashGate.instance.peerCaller = (peerId, frame) async {
        final entries = await remote.list(
          frame.payload['device'] as String,
          frame.space!,
          limit: MirrorHashGate.listLimit,
        );
        return {
          'entries': [for (final e in entries) e.toJson()],
        };
      };

      final result = await MirrorHashGate.instance.verify(
        oldMasterId: oldMaster,
        deviceIds: [peerDevice],
        store: local,
      );
      expect(result.ok, isFalse);
      expect(
        result.mismatches.any((m) => m.kind == 'hash_mismatch'),
        isTrue,
      );
    });
  });
}
