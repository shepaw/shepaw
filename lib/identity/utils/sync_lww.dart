/// Last-write-wins helpers for sync apply / commit paths.
class SyncLww {
  SyncLww._();

  static bool isIncomingStale({
    required int incomingWallTimeMs,
    required int existingWallTimeMs,
  }) =>
      existingWallTimeMs > 0 && incomingWallTimeMs < existingWallTimeMs;

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
