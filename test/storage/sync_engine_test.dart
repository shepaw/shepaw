import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/storage/device_cursor_store.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/sync_engine.dart';
import 'package:shepaw/storage/sync_journal.dart';

import 'test_harness.dart';

/// 进程内仿真的 master：LocalStore + 游标账，镜像协议语义。
class FakeMaster {
  FakeMaster(this.store, this.cursors);

  final LocalStore store;
  final DeviceCursorStore cursors;
  final opLog = <String>[];
  bool online = true;
  int failOnCall = -1; // 第 N 次调用注入失败（-1 不注入）
  var _callCount = 0;

  /// master 侧的写盘不触发本进程的静态 journal——
  /// 那是客户端的队列（真实部署中两侧是不同进程，天然隔离）。
  Future<T> _silent<T>(Future<T> Function() action) async {
    final prev = LocalStore.syncJournal;
    LocalStore.syncJournal = null;
    try {
      return await action();
    } finally {
      LocalStore.syncJournal = prev;
    }
  }

  Future<Map<String, dynamic>?> call(String caller, StoreFrame frame) async {
    _callCount++;
    if (_callCount == failOnCall) return {'_error': 'injected'};
    opLog.add(frame.op);
    switch (frame.op) {
      case StoreOp.syncHello:
        return {'applied_seq': await cursors.appliedSeq(caller)};
      case StoreOp.writeBegin:
        final (id, received) = await store.writeBegin(
          deviceId: caller,
          space: frame.payload['space'] as String,
          path: frame.payload['path'] as String,
          size: frame.payload['size'] as int,
          sha256: frame.payload['sha256'] as String,
        );
        return {'upload_id': id, 'received': received};
      case StoreOp.writeChunk:
        final received = await store.writeChunk(
          caller,
          frame.payload['space'] as String,
          frame.payload['upload_id'] as String,
          frame.payload['offset'] as int,
          base64Decode(frame.payload['data'] as String),
        );
        return {'received': received};
      case StoreOp.commit:
        final (committed, failed) = await _silent(() => store.commit(
          caller,
          frame.payload['space'] as String,
          (frame.payload['upload_ids'] as List).cast<String>(),
        ));
        final upto = frame.payload['upto_seq'] as int?;
        final applied =
            upto != null && failed.isEmpty ? await cursors.advance(caller, upto) : null;
        return {
          'committed': [for (final f in committed) f.path],
          'failed': failed,
          if (applied != null) 'applied_seq': applied,
        };
      case StoreOp.delete:
        try {
          await _silent(() => store.delete(caller, frame.payload['space'] as String,
              frame.payload['path'] as String));
        } on StoreException catch (e) {
          if (e.code != StoreError.notFound) rethrow;
          final upto = frame.payload['upto_seq'] as int?;
          return {
            'recycled': '',
            'already_gone': true,
            if (upto != null) 'applied_seq': await cursors.advance(caller, upto),
          };
        }
        final upto = frame.payload['upto_seq'] as int?;
        return {
          'recycled': '.recycle/x',
          if (upto != null) 'applied_seq': await cursors.advance(caller, upto),
        };
      case StoreOp.meta:
        try {
          return await store.meta(
            frame.payload['device'] as String? ?? caller,
            frame.payload['space'] as String,
            frame.payload['path'] as String,
          );
        } on StoreException catch (e) {
          return {'_error': e.code};
        }
      default:
        return {'_error': 'unsupported'};
    }
  }
}

class FakeTransport implements SyncTransport {
  FakeTransport(this.master, this.caller);

  final FakeMaster master;
  final String caller;

  @override
  Future<bool> get isMasterOnline async => master.online;

  @override
  Future<Map<String, dynamic>?> call(StoreFrame frame) async {
    if (!master.online) return <String, dynamic>{'_error': 'offline'};
    return master.call(caller, frame);
  }
}

/// M4 同步引擎：未同步队列 + 变更游标 + 批量原子上传（spec §6）。
void main() {
  late Directory clientRoot, masterRoot;
  late LocalStore clientStore, masterStore;
  late FakeMaster master;
  late FakeTransport transport;
  late SyncEngine engine;
  String selfId = '';

  setUpAll(() async {
    await StorageTestHarness.init();
    selfId = await DeviceIdentity.deviceId();
  });

  setUp(() async {
    clientRoot = await Directory.systemTemp.createTemp('sync_client');
    masterRoot = await Directory.systemTemp.createTemp('sync_master');
    clientStore = LocalStore(root: clientRoot);
    masterStore = LocalStore(root: masterRoot);
    master = FakeMaster(
        masterStore, DeviceCursorStore(storeRoot: masterRoot));
    transport = FakeTransport(master, selfId);
    engine = SyncEngine();
    await engine.start(
      storeRoot: clientRoot,
      store: clientStore,
      transport: transport,
      masterDeviceIdFn: () async => 'ffffffffffffffff',
      autoSync: false,
    );
  });

  tearDown(() async {
    await engine.stop();
    LocalStore.syncJournal = null;
  });

  Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));
  String sha(Uint8List b) => crypto.sha256.convert(b).toString();

  Future<void> clientCommit(String path, Uint8List content,
      {String space = 'files'}) async {
    final (uid, _) = await clientStore.writeBegin(
        deviceId: selfId,
        space: space,
        path: path,
        size: content.length,
        sha256: sha(content));
    await clientStore.writeChunk(selfId, space, uid, 0, content);
    await clientStore.commit(selfId, space, [uid]);
  }

  Future<Uint8List> masterReadAll(String path, int size,
      {String space = 'files'}) async {
    final builder = BytesBuilder(copy: false);
    var offset = 0;
    while (offset < size) {
      final (chunk, _, eof) = await masterStore.read(
          selfId, space, path, offset, LocalStore.maxReadChunk);
      builder.add(chunk);
      offset += chunk.length;
      if (eof) break;
    }
    return builder.toBytes();
  }

  test('本地 commit 入队；master 上线后镜像一致、游标对齐、队列清空', () async {
    master.online = false;
    final c1 = bytesOf('file one');
    final c2 = bytesOf('file two!!');
    await clientCommit('a.txt', c1);
    await clientCommit('b.txt', c2);

    // 离线：队列留存，master 无数据
    await engine.syncNow();
    expect((await engine.journal!.pending()).length, 2);
    expect(await masterStore.list(selfId, 'files'), isEmpty);

    // 上线：全部镜像
    master.online = true;
    await engine.syncNow();

    expect((await masterStore.list(selfId, 'files')).length, 2);
    expect(await masterReadAll('a.txt', c1.length), c1);
    expect(await masterReadAll('b.txt', c2.length), c2);

    // 游标水位对齐
    final cursors = await engine.journal!.cursors();
    expect(cursors.ackSeq, cursors.changeSeq);
    expect(await master.cursors.appliedSeq(selfId), cursors.changeSeq);
    expect((await engine.journal!.pending()), isEmpty);
  });

  test('commit 标记最后送达：write.chunk 全部先于 commit，条目按 seq 顺序',
      () async {
    await clientCommit('f1.txt', bytesOf('1'));
    await clientCommit('f2.txt', bytesOf('2'));
    await engine.syncNow();

    final commitIdx = [
      for (var i = 0; i < master.opLog.length; i++)
        if (master.opLog[i] == StoreOp.commit) i,
    ];
    expect(commitIdx.length, 2);
    // 每笔 commit 前的最后非 commit 帧都是 write.chunk（内容先于标记）
    expect(master.opLog[commitIdx[0] - 1], StoreOp.writeChunk);
    expect(master.opLog[commitIdx[1] - 1], StoreOp.writeChunk);
    // 第一笔条目的所有 chunk 都在第一笔 commit 之前
    final firstCommit = commitIdx[0];
    expect(master.opLog.sublist(0, firstCommit).contains(StoreOp.commit),
        isFalse);
  });

  test('游标对账：master 已应用的 seq 不重复上传', () async {
    await clientCommit('x.txt', bytesOf('x'));
    await clientCommit('y.txt', bytesOf('y'));
    // master 预先把游标推到 1（模拟此前已送达第一笔）
    await master.cursors.advance(selfId, 1);

    await engine.syncNow();
    // 只有一次 commit（第二笔）
    expect(master.opLog.where((op) => op == StoreOp.commit).length, 1);
    expect((await masterStore.list(selfId, 'files')).single.path, 'y.txt');
    // 第一笔直接出队
    expect((await engine.journal!.pending()), isEmpty);
    expect((await engine.journal!.cursors()).ackSeq, 2);
  });

  test('删除重放：master 侧文件进回收站', () async {
    await clientCommit('d.txt', bytesOf('dd'));
    master.online = true;
    await engine.syncNow();
    expect((await masterStore.list(selfId, 'files')).single.path, 'd.txt');

    await clientStore.delete(selfId, 'files', 'd.txt');
    await engine.syncNow();

    expect(await masterStore.list(selfId, 'files'), isEmpty);
    final recycle = await masterStore.recycleList();
    expect(recycle.any((e) => e.originPath == 'd.txt'), isTrue);
  });

  test('删除幂等：master 已无文件时重放仍成功出队', () async {
    await clientCommit('gone.txt', bytesOf('g'));
    await engine.syncNow();
    // 模拟 master 侧已被别处删除（不经本机 journal）
    final prev = LocalStore.syncJournal;
    LocalStore.syncJournal = null;
    await masterStore.delete(selfId, 'files', 'gone.txt');
    LocalStore.syncJournal = prev;
    await clientStore.delete(selfId, 'files', 'gone.txt');
    await engine.syncNow();
    expect((await engine.journal!.pending()), isEmpty);
    expect((await engine.journal!.cursors()).ackSeq, 2);
  });

  test('ack 自愈：master applied 落后时回退 ack 并差量重推', () async {
    final c = bytesOf('heal-me');
    await clientCommit('heal.txt', c);
    await engine.syncNow();
    expect((await engine.journal!.cursors()).ackSeq, 1);

    // 模拟新 master：游标落后且缺 blob（种子缺口）
    final prev = LocalStore.syncJournal;
    LocalStore.syncJournal = null;
    await masterStore.delete(selfId, 'files', 'heal.txt');
    LocalStore.syncJournal = prev;
    final cursorFile =
        File(p.join(masterRoot.path, '.system', 'device_cursors.json'));
    await cursorFile.parent.create(recursive: true);
    await cursorFile.writeAsString(jsonEncode({selfId: 0}));
    master = FakeMaster(masterStore, DeviceCursorStore(storeRoot: masterRoot));
    transport = FakeTransport(master, selfId);
    await engine.stop();
    LocalStore.syncJournal = null;
    engine = SyncEngine();
    await engine.start(
      storeRoot: clientRoot,
      store: clientStore,
      transport: transport,
      masterDeviceIdFn: () async => 'ffffffffffffffff',
      autoSync: false,
    );
    expect((await engine.journal!.cursors()).ackSeq, 1);

    await engine.syncNow();
    expect(await masterReadAll('heal.txt', c.length), c);
    expect(await master.cursors.appliedSeq(selfId), greaterThanOrEqualTo(1));
  });

  test('上传失败保序：失败条目留队，恢复后从断点续传', () async {
    await clientCommit('ok.txt', bytesOf('ok'));
    await clientCommit('retry.txt', bytesOf('retry'));

    // 第一笔 commit 后注入一次失败
    final firstCommitCall = 1 + // hello
        3 + // 第一笔：begin+chunk+commit（小文件 1 块）
        1; // 第二笔 begin → 失败
    master.failOnCall = firstCommitCall;
    await engine.syncNow();

    var pending = await engine.journal!.pending();
    expect(pending.length, 1);
    expect(pending.single.seq, 2);

    master.failOnCall = -1;
    await engine.syncNow();
    expect((await engine.journal!.pending()), isEmpty);
    expect(await masterReadAll('retry.txt', 5), bytesOf('retry'));
  });

  test('master 是本机：本地变更直接出队、零上传帧', () async {
    await engine.stop();
    LocalStore.syncJournal = null;
    engine = SyncEngine();
    await engine.start(
      storeRoot: clientRoot,
      store: clientStore,
      transport: transport,
      masterDeviceIdFn: () async => selfId,
      autoSync: false,
    );
    await clientCommit('local.txt', bytesOf('local'));
    master.opLog.clear();
    await engine.syncNow();
    expect((await engine.journal!.pending()), isEmpty);
    expect(master.opLog, isEmpty);
  });

  test('快照目录（含子路径）经队列镜像', () async {
    master.online = true;
    final content = bytesOf('snapshot-bytes');
    await clientCommit('snap-1/db.sqlite.enc', content, space: 'backups');
    await engine.syncNow();
    final list = await masterStore.list(selfId, 'backups');
    expect(list.single.path, 'snap-1/db.sqlite.enc');
    expect(list.single.sha256, sha(content));
  });

  test('status 流：入队后有待同步，syncNow 后清空', () async {
    master.online = false;
    final seen = <int>[];
    final sub = engine.status.listen((s) => seen.add(s.pendingCount));

    await clientCommit('s.txt', bytesOf('status'));
    final queued = await engine.currentStatus();
    expect(queued.pendingCount, greaterThan(0));
    expect(queued.masterIsSelf, isFalse);
    expect(queued.showPendingCard, isTrue);
    expect(queued.items.single.path, 's.txt');

    master.online = true;
    await engine.syncNow();
    final done = engine.latestStatus;
    expect(done.pendingCount, 0);
    expect(done.isSyncing, isFalse);
    expect(done.uploadingSeq, isNull);
    await sub.cancel();
    expect(seen.any((n) => n > 0), isTrue);
    expect(seen.last, 0);
  });
}
