/// 把本机 v2 的玉简存量（`slips/<device>/…`）一次性导入 v3 袋子。
///
/// 旧 App 把玉简写在 **本机** store 的 `slips/<设备指纹>/<id>.json`（附件在
/// `<id>/files/`）；v3 的权威是 hub 上的 `slip:<id>` scope（`slip.json` +
/// `files/<file>`）。切到 scope 之后旧的读路径看不到这些简，所以升级后第一次
/// 打开玉简页时补一次导入。
///
/// - 只补不覆盖：host 上已有同 id 的记录/附件就跳过（hub 那份可能更新）；
/// - 幂等：按袋子 id 记标记，换袋子自然重跑；
/// - 非破坏：本机 v2 副本不动，等 v2 下线时统一清；
/// - 主机不在线不落标记，下次再试。
library;

import 'package:flutter/foundation.dart';

import '../models/jade_slip.dart';
import '../storage/local_store.dart';
import '../storage/pouch_scope.dart';
import '../storage/pouch_scope_store.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import 'local_database_service.dart';
import 'logger_service.dart';

class SlipScopeMigration {
  SlipScopeMigration._();

  static const _tag = 'SlipScopeMigration';

  /// 已导入到哪只袋子（存 pouch id）。
  static const markerKey = 'storage.slips_v3_imported_pouch';

  static final _log = LoggerService();

  /// 本进程内已处理过的袋子，避免每次 list 都扫一遍本机。
  static String? _settled;
  static Future<void>? _inflight;

  /// 测试注入：绕过 sqflite。
  @visibleForTesting
  static Future<String?> Function()? debugReadMarker;

  @visibleForTesting
  static Future<void> Function(String pouchId)? debugWriteMarker;

  @visibleForTesting
  static void resetForTest() {
    _settled = null;
    _inflight = null;
    debugReadMarker = null;
    debugWriteMarker = null;
  }

  /// 幂等入口：有 v3 袋子才跑；同一进程内只跑一次（同一时刻只跑一个）。
  static Future<void> ensure() {
    final running = _inflight;
    if (running != null) return running;
    late final Future<void> run;
    run = _run().whenComplete(() {
      if (identical(_inflight, run)) _inflight = null;
    });
    _inflight = run;
    return run;
  }

  static Future<void> _run() async {
    final PouchScopeStore scoped;
    try {
      scoped = await StoreService.instance.scopeStore();
    } on StoreException {
      // 没有 v3 袋子（还没登录/本机没有 hub）：没有目标，什么都不用做。
      return;
    }
    final pouchId = scoped.pouchId;
    if (pouchId.isEmpty || _settled == pouchId) return;
    try {
      if (await _readMarker() == pouchId) {
        _settled = pouchId;
        return;
      }
      final moved = await _import(scoped);
      _settled = pouchId;
      await _writeMarker(pouchId);
      if (moved > 0) {
        _log.info('imported $moved 玉简 into pouch $pouchId', tag: _tag);
      }
    } on StoreException catch (e) {
      if (e.code == StoreError.masterOffline ||
          e.code == StoreError.notPaired) {
        // 主机不在线：不落标记，下次连上再试。
        return;
      }
      _log.warning('import slips into pouch $pouchId: $e', tag: _tag);
      _settled = pouchId;
    } catch (e) {
      _log.warning('import slips into pouch $pouchId: $e', tag: _tag);
      _settled = pouchId;
    }
  }

  /// 扫本机所有 device 目录，把 hub 上还没有的玉简补进去。返回导入条数。
  static Future<int> _import(PouchScopeStore scoped) async {
    final LocalStore local;
    try {
      local = await StoreService.instance.localStore();
    } catch (_) {
      return 0; // 本机还没有 store：没有存量
    }
    final devices = await local.listDeviceIds();
    final ids = <String>{};
    for (final device in devices) {
      final entries = await local.list(
        device,
        StoreSpace.slips,
        depth: 1,
        computeHash: false,
      );
      for (final entry in entries) {
        final id = entry.isDir
            ? entry.path.trim()
            : JadeSlip.idFromRecordPath(entry.path);
        if (id != null && isValidPouchScopeId(id)) ids.add(id);
      }
    }
    var moved = 0;
    for (final id in ids) {
      final scope = PouchScope.slip(id);
      moved += await _importRecord(local, scoped, scope, id, devices);
      moved += await _importAttachments(local, scoped, scope, id, devices);
    }
    return moved;
  }

  /// 补记录：所有 device 目录里第一份能读到、且 hub 还没有的 `<id>.json`。
  static Future<int> _importRecord(
    LocalStore local,
    PouchScopeStore scoped,
    PouchScope scope,
    String id,
    List<String> devices,
  ) async {
    if (await scoped.meta(scope, 'slip.json') != null) return 0;
    for (final device in devices) {
      final bytes = await _readAll(local, device, '$id.json');
      if (bytes == null) continue;
      await scoped.write(scope, 'slip.json', bytes);
      return 1;
    }
    return 0;
  }

  /// 补 `<id>/files/*`：scope 里已有同名文件就跳过。
  static Future<int> _importAttachments(
    LocalStore local,
    PouchScopeStore scoped,
    PouchScope scope,
    String id,
    List<String> devices,
  ) async {
    final dir = '$id/files';
    var moved = 0;
    for (final device in devices) {
      final entries = await local.list(
        device,
        StoreSpace.slips,
        prefix: dir,
        depth: 1,
        computeHash: false,
      );
      for (final entry in entries) {
        if (entry.isDir || !entry.path.startsWith('$dir/')) continue;
        final name = entry.path.substring(dir.length + 1);
        if (name.isEmpty) continue;
        final path = 'files/$name';
        if (await scoped.meta(scope, path) != null) continue;
        final bytes = await _readAll(local, device, entry.path);
        if (bytes == null) continue;
        await scoped.write(scope, path, bytes);
        moved++;
      }
    }
    return moved;
  }

  static Future<Uint8List?> _readAll(
    LocalStore store,
    String device,
    String path,
  ) async {
    const chunk = LocalStore.maxBinaryReadChunk;
    final pieces = <int>[];
    var offset = 0;
    try {
      while (true) {
        final (data, _, eof) =
            await store.read(device, StoreSpace.slips, path, offset, chunk);
        pieces.addAll(data);
        if (eof || data.isEmpty) break;
        offset += data.length;
      }
    } on StoreException catch (e) {
      if (e.code == StoreError.notFound) return null;
      rethrow;
    }
    return Uint8List.fromList(pieces);
  }

  static Future<String?> _readMarker() async {
    final injected = debugReadMarker;
    if (injected != null) return injected();
    try {
      return await LocalDatabaseService().getUserValue(markerKey);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeMarker(String pouchId) async {
    final injected = debugWriteMarker;
    if (injected != null) {
      await injected(pouchId);
      return;
    }
    await LocalDatabaseService().setUserValue(markerKey, pouchId);
  }
}
