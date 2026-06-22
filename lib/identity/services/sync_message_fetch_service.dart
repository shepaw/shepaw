import '../../services/local_database_service.dart';
import '../models/device_role.dart';
import '../models/sync_event.dart';
import 'account_identity_service.dart';
import 'device_rpc_service.dart';
import 'storage_device_service.dart';
import 'sync_engine.dart';

/// App 设备按需从 Primary 拉取单条消息正文。
class SyncMessageFetchService {
  SyncMessageFetchService._();
  static final SyncMessageFetchService instance = SyncMessageFetchService._();

  final _db = LocalDatabaseService();

  /// 若本地无正文，尝试经 RPC 从 Primary 拉取并缓存。
  Future<Map<String, dynamic>?> fetchMessageBody(String messageId) async {
    final existing = await _db.getMessageById(messageId, fetchRemote: false);
    if (existing != null) return existing;

    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.app) return null;

    for (final device in await StorageDeviceService.devicesInFetchOrder()) {
      try {
        final resp = await DeviceRpcService.instance.call(
          targetDeviceId: device.deviceId,
          method: 'messages.fetch',
          params: {'message_id': messageId},
          timeout: const Duration(seconds: 15),
        );
        if (resp['error'] != null) continue;
        final row = resp['message'];
        if (row is! Map) continue;
        final messageRow = Map<String, dynamic>.from(row);
        await SyncEngine.instance.applyMessageEvents([
          SyncEvent.messageEvent(
            messageRow: messageRow,
            originDeviceId: device.deviceId,
          ),
        ]);
        return _db.getMessageById(messageId, fetchRemote: false);
      } catch (_) {
        continue;
      }
    }
    return null;
  }
}
