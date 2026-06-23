/// sync_query 分页与 limit 上限。
class SyncQueryLimits {
  SyncQueryLimits._();

  static const defaultLimit = 50;
  static const maxLimit = 200;
  static const clientPageSize = 50;
  static const maxClientPages = 200;

  static int clampLimit(int? raw) {
    final value = raw ?? defaultLimit;
    if (value < 1) return 1;
    if (value > maxLimit) return maxLimit;
    return value;
  }
}
