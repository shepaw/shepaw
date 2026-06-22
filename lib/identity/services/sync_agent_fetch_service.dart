import '../../services/local_database_service.dart';
import '../models/device_role.dart';
import '../models/sync_event.dart';
import 'account_identity_service.dart';
import 'device_rpc_service.dart';
import 'sync_engine.dart';

/// App 设备按需从 Primary 拉取单个 Agent 记录。
class SyncAgentFetchService {
  SyncAgentFetchService._();
  static final SyncAgentFetchService instance = SyncAgentFetchService._();

  final _db = LocalDatabaseService();

  Future<Map<String, dynamic>?> fetchAgentRow(String agentId) async {
    final existing = await _db.getAgentRowById(agentId);
    if (existing != null) return existing;

    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.app) return null;

    final primary = await AccountIdentityService.instance.primaryDevice();
    if (primary == null) return null;

    try {
      final resp = await DeviceRpcService.instance.call(
        targetDeviceId: primary.deviceId,
        method: 'agents.fetch',
        params: {'agent_id': agentId},
        timeout: const Duration(seconds: 15),
      );
      final row = resp['agent'];
      if (row is! Map) return null;
      final agentRow = Map<String, dynamic>.from(row);
      await SyncEngine.instance.applyAgentEvents([
        SyncEvent.agentEvent(
          agentRow: agentRow,
          originDeviceId: primary.deviceId,
        ),
      ]);
      return _db.getAgentRowById(agentId);
    } catch (_) {
      return null;
    }
  }
}
