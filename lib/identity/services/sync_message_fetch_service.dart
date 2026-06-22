import '../../services/local_database_service.dart';
import '../models/device_role.dart';
import '../models/sync_event.dart';
import 'account_identity_service.dart';
import 'device_rpc_service.dart';
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

    final primary = await AccountIdentityService.instance.primaryDevice();
    if (primary == null) return null;

    try {
      final resp = await DeviceRpcService.instance.call(
        targetDeviceId: primary.deviceId,
        method: 'messages.fetch',
        params: {'message_id': messageId},
        timeout: const Duration(seconds: 15),
      );
      final row = resp['message'];
      if (row is! Map) return null;
      final messageRow = Map<String, dynamic>.from(row);
      await SyncEngine.instance.applyMessageEvents([
        SyncEvent.messageEvent(
          messageRow: messageRow,
          originDeviceId: primary.deviceId,
        ),
      ]);
      return _db.getMessageById(messageId, fetchRemote: false);
    } catch (_) {
      return null;
    }
  }
}
