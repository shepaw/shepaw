import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'store_service.dart';
import 'sync_journal.dart';

/// 危险区：清空本机 store 设备树结果（方案 §7.5）。
class StoreWipeResult {
  StoreWipeResult({required this.freedBytes});

  final int freedBytes;
}

/// 删除本机 `<device_id>/` 四分区（含 staging），清空 SyncJournal 待同步队列。
///
/// 保留 change_seq 以免撞 master 游标；不删他端镜像、`.recycle`、身份与 DB。
class StoreWipeService {
  StoreWipeService._();
  static final StoreWipeService instance = StoreWipeService._();

  static const _tag = 'StoreWipe';
  final _log = LoggerService();

  Future<StoreWipeResult> wipeSelfTree() async {
    final self = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    final freed = await store.wipeSelf(self);

    final journal = LocalStore.syncJournal;
    if (journal != null && journal.ownerDeviceId == self) {
      await journal.clearPendingQueue();
    } else {
      // SyncEngine 未挂接时仍清磁盘队列，避免残留幽灵条目。
      final orphan = SyncJournal(storeRoot: store.root, ownerDeviceId: self);
      await orphan.clearPendingQueue();
    }

    _log.info('wiped self store ($freed bytes)', tag: _tag);
    return StoreWipeResult(freedBytes: freed);
  }
}
