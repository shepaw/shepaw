/// Last-write-wins helpers for sync apply / commit paths.
class SyncLww {
  SyncLww._();

  /// 较新的写入胜出；同毫秒时按 eventId、originDeviceId 字典序决胜。
  static bool isIncomingStale({
    required int incomingWallTimeMs,
    required int existingWallTimeMs,
    String incomingEventId = '',
    String existingEventId = '',
    String incomingOriginDeviceId = '',
    String existingOriginDeviceId = '',
  }) {
    if (existingWallTimeMs > 0 && incomingWallTimeMs < existingWallTimeMs) {
      return true;
    }
    if (incomingWallTimeMs != existingWallTimeMs || existingWallTimeMs <= 0) {
      return false;
    }
    if (incomingEventId.isNotEmpty &&
        existingEventId.isNotEmpty &&
        incomingEventId != existingEventId) {
      return incomingEventId.compareTo(existingEventId) < 0;
    }
    if (incomingOriginDeviceId.isNotEmpty &&
        existingOriginDeviceId.isNotEmpty &&
        incomingOriginDeviceId != existingOriginDeviceId) {
      return incomingOriginDeviceId.compareTo(existingOriginDeviceId) < 0;
    }
    return false;
  }

  static int isoRowTimeMs(
    Map<String, dynamic> row,
    List<String> keys,
  ) {
    for (final key in keys) {
      final raw = row[key];
      if (raw is String && raw.isNotEmpty) {
        final ms = DateTime.tryParse(raw)?.millisecondsSinceEpoch;
        if (ms != null) return ms;
      }
    }
    return 0;
  }

  static int intRowTimeMs(
    Map<String, dynamic> row,
    List<String> keys,
  ) {
    for (final key in keys) {
      final raw = row[key];
      if (raw is int) return raw;
    }
    return 0;
  }
}
