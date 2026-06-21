/// 跨设备加入账号的结果。
class AccountJoinResult {
  /// 本机已有该账号，仅重新连接并同步。
  final bool reconnected;

  /// 增量同步是否成功。
  final bool syncSucceeded;

  /// 同步失败时的错误信息。
  final String? syncError;

  const AccountJoinResult({
    required this.reconnected,
    required this.syncSucceeded,
    this.syncError,
  });
}

enum AccountJoinProgress {
  waitingApproval,
  connectingAccount,
  syncing,
}
