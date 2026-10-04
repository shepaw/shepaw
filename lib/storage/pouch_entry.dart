import 'pouch_session.dart';

/// 解锁之后去选择页，还是带着现有登录态进主页。
enum PouchEntryDecision { resume, choose }

/// 储物袋选择页的路由参数。`switching` 时不自动进入唯一的那只袋子。
class PouchLoginArgs {
  const PouchLoginArgs({
    this.switching = false,
    this.hostUnresponsive = false,
  });

  final bool switching;

  /// 本机主机地址已经改回环，但 8 秒内没有连上。
  final bool hostUnresponsive;
}

/// 电脑端只有本机 CLI 还在跑、而且登录态里那台主机就是它时才恢复。
/// 手机端登录态有效就恢复，主机离线不拦着。
PouchEntryDecision decidePouchEntry({
  required PouchSession? session,
  required int nowMs,
  required bool isDesktop,
  String? localCliFingerprint,
  String? sessionHostFingerprint,
}) {
  if (session == null || !session.isLoggedIn(nowMs)) {
    return PouchEntryDecision.choose;
  }
  if (!isDesktop) return PouchEntryDecision.resume;
  final local = localCliFingerprint?.trim() ?? '';
  final host = sessionHostFingerprint?.trim() ?? '';
  if (local.isEmpty || host.isEmpty || local != host) {
    return PouchEntryDecision.choose;
  }
  return PouchEntryDecision.resume;
}
