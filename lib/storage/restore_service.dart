import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/agent_memory_db_service.dart';
import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import '../services/minds_database_service.dart';
import '../services/password_service.dart';
import '../services/she_memory_db_service.dart';
import '../services/she_profile_database_service.dart';
import 'device_identity.dart';
import 'snapshot_service.dart';

/// 恢复引擎（docs/storage_space_plan.md §5.3）。
///
/// 流程：验 manifest → 密码解密 → 安全快照 → 全量替换 → 重启生效。
/// 恢复是全量替换、不合并。
class RestoreService {
  RestoreService._();
  static final RestoreService instance = RestoreService._();

  static const _tag = 'Restore';
  final _log = LoggerService();

  /// 恢复前检查：manifest 校验 + 密码可解 + 内容哈希一致。
  ///
  /// 返回解密后的 DB 明文供 [executeRestore] 使用；任何一步失败抛异常，
  /// 当前数据不受影响。
  Future<RestorePreview> prepareRestore(
      SnapshotInfo info, String password) async {
    if (kIsWeb) {
      throw UnsupportedError('web 平台不支持快照恢复');
    }
    // 1. manifest / 密文完整性
    final status = await SnapshotService.instance.verifySnapshot(info);
    if (status != SnapshotVerifyStatus.ok) {
      throw StateError('snapshot verify failed: $status');
    }
    // 2. 密码必须与当前主密码一致（§10 强制验密）
    if (!await PasswordService().verifyPassword(password)) {
      throw StateError('wrong password');
    }
    // 3. 解密（含内容哈希校验）
    final dbBytes = await SnapshotService.instance.decryptDb(info, password);
    final identityBytes =
        await SnapshotService.instance.decryptIdentity(info, password);
    return RestorePreview(
      snapshot: info,
      dbBytes: dbBytes,
      identityBytes: identityBytes,
    );
  }

  /// 执行恢复。调用前必须经 [prepareRestore] 成功。
  ///
  /// 安全网：先对当前状态做一次安全快照（同一密码），再把现有主库文件
  /// 改名保留为 shepaw.db.pre-restore。恢复后 app 需重启生效。
  Future<void> executeRestore(RestorePreview preview, String password) async {
    if (kIsWeb) {
      throw UnsupportedError('web 平台不支持快照恢复');
    }
    // 1. 当前状态安全快照（§5.3：恢复前自动留存本机安全快照）
    try {
      await SnapshotService.instance.createSnapshot(password: password);
    } catch (e) {
      _log.warning('safety snapshot failed, abort restore: $e', tag: _tag);
      throw StateError('safety snapshot failed: $e');
    }

    // 2. 关闭全部 DB 连接
    await _closeAllDatabases();

    // 3. 全量替换主库（保留 .pre-restore 兜底）
    final docs = await getApplicationDocumentsDirectory();
    final dbFile = File(p.join(docs.path, 'shepaw.db'));
    final backup = File(p.join(docs.path, 'shepaw.db.pre-restore'));
    if (await backup.exists()) await backup.delete();
    if (await dbFile.exists()) {
      await dbFile.rename(backup.path);
    }
    try {
      await dbFile.writeAsBytes(preview.dbBytes, flush: true);
    } catch (e) {
      // 写失败回滚
      if (await backup.exists()) await backup.rename(dbFile.path);
      rethrow;
    }

    // 4. 恢复设备身份（device_id 随快照恢复，§5.4）
    await DeviceIdentity.importIdentity(preview.identityBytes);

    _log.info(
        'restore executed from ${preview.snapshot.id}; restart required',
        tag: _tag);
  }

  /// 恢复后清理：删除 .pre-restore 兜底文件（用户确认恢复成功后）。
  Future<void> discardPreRestoreBackup() async {
    if (kIsWeb) return;
    final docs = await getApplicationDocumentsDirectory();
    final backup = File(p.join(docs.path, 'shepaw.db.pre-restore'));
    if (await backup.exists()) await backup.delete();
  }

  Future<void> _closeAllDatabases() async {
    await LocalDatabaseService().close();
    await SheProfileDatabaseService().close();
    await SheMemoryDbService.instance.close();
    await MindsDatabaseService().close();
    await AgentMemoryDbService.closeAll();
  }
}

/// [RestoreService.prepareRestore] 的产物。
class RestorePreview {
  RestorePreview({
    required this.snapshot,
    required this.dbBytes,
    required this.identityBytes,
  });

  final SnapshotInfo snapshot;
  final Uint8List dbBytes;
  final Uint8List identityBytes;
}
