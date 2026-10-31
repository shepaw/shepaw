import '../peer/pairing_endpoints.dart';
import '../storage/pouch_session.dart';
import 'host_entry.dart';

/// 这台设备为什么需要输一次主机密码。解锁页用它决定要不要显示原因条。
enum UnlockReason {
  /// 登录态到期。最常见，解锁页不额外解释。
  expired,

  /// 设备凭据被主机拒绝（改过密码、或被移除过）。
  credentialRejected,

  /// 主机重启丢了登录态，keeper 把用户带到解锁页。
  hostRestarted,

  /// 加入码失效，退回输密码。
  inviteInvalid,

  /// 用户主动换了一台主机。
  switched,
}

/// 为什么要进「准备主机」那一页。
enum HostInstallReason {
  /// 没装过 shepaw。
  firstInstall,

  /// 装了但没在跑。
  notRunning,

  /// 在跑，但探测不到密码状态 / 连不上。
  unresponsive,
}

/// 解锁之后去哪。
///
/// 它只描述「去哪」，不做任何 IO。输入全部由 [GateNavigator] 准备好，
/// 这样整张决策表可以用纯单测覆盖。
sealed class GateEntry {
  const GateEntry({this.recordMode});

  /// 非空时调用方把 `host_mode` 写成这个值。
  final HostMode? recordMode;
}

/// 登录态还有效，直接进主页。
class GoHome extends GateEntry {
  const GoHome({super.recordMode});
}

/// 有设备凭据，先静默续期。续不回来再走 [fallback]。
class TryRestore extends GateEntry {
  const TryRestore({
    required this.hostPeerId,
    required this.fallback,
    super.recordMode,
  });

  final String hostPeerId;
  final GateEntry fallback;
}

/// 第一次进来：选主机放哪（桌面），或者扫码加入（手机）。
class GoWelcome extends GateEntry {
  const GoWelcome({super.recordMode});
}

/// 桌面本机：主机还没准备好。
class GoHostInstall extends GateEntry {
  const GoHostInstall({required this.reason, super.recordMode});

  final HostInstallReason reason;
}

/// 桌面本机：这台主机还没设过密码。
class GoCreatePassword extends GateEntry {
  const GoCreatePassword({super.recordMode});
}

/// 要输一次主机密码。
class GoUnlock extends GateEntry {
  const GoUnlock({
    required this.hostPeerId,
    this.reason = UnlockReason.expired,
    super.recordMode,
  });

  /// 本机主机。它的 peer id 要等 `CliHost.ensurePaired` 之后才知道，
  /// 所以这里留空，由调用方补上。
  const GoUnlock.local({
    this.reason = UnlockReason.expired,
    super.recordMode,
  }) : hostPeerId = '';

  final String hostPeerId;

  final UnlockReason reason;

  /// 空表示「本机主机」，调用方要解析出真实的 peer id。
  bool get isLocalHost => hostPeerId.trim().isEmpty;
}

/// 自上而下命中即返回。`unset` 会带上要写回的 [GateEntry.recordMode]。
///
/// 表的顺序就是判定的顺序，见 `docs/login_flow_redesign_decision.md` 3.3。
GateEntry resolveGate({
  required bool isDesktop,
  required HostMode mode,
  required LocalCliStatus cli,
  required bool? localPasswordSet,
  required PouchSession? session,
  required bool credentialValid,
  required String? rememberedHostId,
  required int nowMs,
  String? localCliFingerprint,
  String? sessionHostFingerprint,
}) {
  final loggedIn = session != null && session.isLoggedIn(nowMs);
  final hostIsLocal =
      sameFingerprint(localCliFingerprint, sessionHostFingerprint);

  // 1. 登录态还在就直接进主页。桌面本机模式下还要确认会话的主机就是本机 CLI，
  //    否则那台主机可能已经被换掉了。
  if (loggedIn &&
      (!isDesktop || mode == HostMode.remote || hostIsLocal)) {
    final record = isDesktop && mode == HostMode.unset && hostIsLocal
        ? HostMode.thisComputer
        : null;
    return GoHome(recordMode: record);
  }

  final remembered = rememberedHostId?.trim() ?? '';

  // 2–4. 手机只认记住的那台主机。
  if (!isDesktop) {
    if (remembered.isEmpty) return const GoWelcome();
    if (credentialValid) {
      return TryRestore(
        hostPeerId: remembered,
        fallback: GoUnlock(hostPeerId: remembered),
      );
    }
    return GoUnlock(hostPeerId: remembered);
  }

  // 7–8. 主机在另一台电脑上。
  if (mode == HostMode.remote) {
    return _remote(session, credentialValid, remembered);
  }

  if (mode == HostMode.unset) {
    // 5. 装了而且在跑：老用户无感升级，按本机主机处理。
    if (cli == LocalCliStatus.running) {
      return _local(cli, localPasswordSet, credentialValid, session,
          record: HostMode.thisComputer);
    }
    // 6. 没在跑，但登录过一台远端主机：不能把人推去本机建袋子。
    final host = sessionHostFingerprint?.trim() ?? '';
    if (session != null && host.isNotEmpty && !hostIsLocal) {
      return _remote(session, credentialValid, remembered,
          record: HostMode.remote);
    }
    // 9. 其余情况先问主机放哪。
    return const GoWelcome();
  }

  // 10–14. 主机就是这台电脑。
  return _local(cli, localPasswordSet, credentialValid, session);
}

GateEntry _local(
  LocalCliStatus cli,
  bool? localPasswordSet,
  bool credentialValid,
  PouchSession? session, {
  HostMode? record,
}) {
  // 10.
  if (cli != LocalCliStatus.running) {
    return GoHostInstall(
      reason: cli == LocalCliStatus.notInstalled
          ? HostInstallReason.firstInstall
          : HostInstallReason.notRunning,
      recordMode: record,
    );
  }
  // 11. 探测不到密码状态时不能盲跳解锁页：那会把「主机没响应」说成「请输入密码」。
  if (localPasswordSet == null) {
    return GoHostInstall(
      reason: HostInstallReason.unresponsive,
      recordMode: record,
    );
  }
  // 12.
  if (!localPasswordSet) return GoCreatePassword(recordMode: record);

  final hostId = session?.hostPeerId.trim() ?? '';
  // 13.
  if (credentialValid && hostId.isNotEmpty) {
    return TryRestore(
      hostPeerId: hostId,
      fallback: GoUnlock.local(recordMode: record),
      recordMode: record,
    );
  }
  // 14.
  return GoUnlock.local(recordMode: record);
}

GateEntry _remote(
  PouchSession? session,
  bool credentialValid,
  String remembered, {
  HostMode? record,
}) {
  final hostId = remembered.isNotEmpty
      ? remembered
      : (session?.hostPeerId.trim() ?? '');
  if (hostId.isEmpty) return GoWelcome(recordMode: record);
  if (credentialValid) {
    return TryRestore(
      hostPeerId: hostId,
      fallback: GoUnlock(hostPeerId: hostId, recordMode: record),
      recordMode: record,
    );
  }
  return GoUnlock(hostPeerId: hostId, recordMode: record);
}
