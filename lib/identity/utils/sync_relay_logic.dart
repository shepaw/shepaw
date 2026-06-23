import 'sync_lww.dart';

/// Backup relay 队列 stale 丢弃判定（与 SyncEngine._isStaleUpsert 核心规则一致）。
class SyncRelayLogic {
  SyncRelayLogic._();

  /// 事件是否已被 entity state + 行时间覆盖，可安全 discard relay 行而不 apply。
  static bool isEventStaleAgainstState({
    required int eventWallTimeMs,
    required String eventId,
    required String originDeviceId,
    required int stateWallTimeMs,
    required String stateEventId,
    required String stateOriginDeviceId,
    required int rowWallTimeMs,
  }) {
    if (stateWallTimeMs == 0 && rowWallTimeMs == 0) return false;

    final effectiveMs = rowWallTimeMs > stateWallTimeMs ? rowWallTimeMs : stateWallTimeMs;
    if (effectiveMs == 0) return false;

    final useStateMeta = stateWallTimeMs >= rowWallTimeMs && stateWallTimeMs > 0;
    return SyncLww.isIncomingStale(
      incomingWallTimeMs: eventWallTimeMs,
      existingWallTimeMs: effectiveMs,
      incomingEventId: eventId,
      existingEventId: useStateMeta ? stateEventId : '',
      incomingOriginDeviceId: originDeviceId,
      existingOriginDeviceId: useStateMeta ? stateOriginDeviceId : '',
    );
  }
}
