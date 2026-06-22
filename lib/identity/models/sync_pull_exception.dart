/// Pull 未完成时抛出（含失败的分域列表）。
class SyncPullException implements Exception {
  final String message;
  final List<String> failedDomains;

  const SyncPullException(this.message, this.failedDomains);

  @override
  String toString() => message;
}
