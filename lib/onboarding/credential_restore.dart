import 'dart:async';

import '../peer/models/paired_peer.dart';
import '../peer/pairing_endpoints.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/cli_host.dart';
import '../services/logger_service.dart';
import '../storage/pouch_credential_store.dart';
import '../storage/pouch_grant.dart';
import '../storage/pouch_login_client.dart';
import '../storage/pouch_session.dart';
import '../storage/pouch_login.dart';

/// 静默续期的结果。
enum RestoreResult {
  /// 用设备凭据换回了登录态。
  restored,

  /// 凭据被主机拒绝（改过密码 / 被移除过）。凭据已经删掉。
  rejected,

  /// 连不上主机，或者登录超时。凭据保留，下次再试。
  unreachable,

  /// 根本没有可用的凭据（没登录过、或者已经过期）。
  none,
}

/// 用设备凭据换登录态。注入进来，测试和 keeper 各接一份。
typedef RestoreLogin = Future<PouchLoginGrant> Function({
  required String hostPeerId,
  required String pouchId,
  required String credential,
});

/// 连主机。`redial` 为真时先断开再连：息屏之后留下的多半是半开连接。
typedef RestoreConnect = Future<void> Function(
  PairedPeer peer, {
  required bool redial,
});

/// 打开 App 时不打扰用户地把登录态接回来。
///
/// 主机登录态 3 天过期，设备凭据 30 天有效。以前只有 keeper 收到
/// `pouch_login_required` 时才会用凭据，于是用户每三天就得输一次密码。
/// 这里在冷启动时先试一次。
///
/// 被拦下的那一帧不在这里重发：续期成功后 [PouchLoginKeeper] 会响一次
/// `relogged`，调用方自己重发。
class CredentialRestore {
  CredentialRestore({
    required this.readSession,
    required this.lookupPeer,
    required this.readCredential,
    required this.connect,
    required this.login,
    required this.persist,
    required this.install,
    required this.saveCredential,
    required this.dropCredential,
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 连接这一步最多等多久。登录那一步另算。
  static const connectBudget = Duration(seconds: 4);
  static const loginBudget = Duration(seconds: 3);

  /// 整趟静默续期的预算。Splash 靠它保证不会把人晾在启动页上。
  static const totalBudget = Duration(seconds: 7);

  final Future<PouchSession?> Function() readSession;
  final Future<PairedPeer?> Function(String hostPeerId) lookupPeer;

  /// 读本机这张凭据。要求 pouch 对得上且没过期，否则返回 null。
  final Future<String?> Function({
    required String hostPeerId,
    required String pouchId,
    required int nowMs,
  }) readCredential;

  final RestoreConnect connect;
  final RestoreLogin login;

  /// 这些和 [applyLoginGrant] 用的是同一组回调。
  final Future<void> Function(PouchSession session) persist;
  final void Function(PouchSession session) install;
  final Future<void> Function({
    required String hostPeerId,
    required String pouchId,
    required String credential,
    required int expiresAtMs,
  }) saveCredential;
  final Future<void> Function(String hostPeerId) dropCredential;

  final void Function(String message)? log;
  final DateTime Function() _now;

  /// 连上主机再用凭据换登录态。
  Future<RestoreResult> run({
    required String hostPeerId,
    Duration budget = totalBudget,
  }) async {
    final target = hostPeerId.trim();
    if (target.isEmpty) return RestoreResult.none;
    final session = await readSession();
    if (session == null ||
        session.hostPeerId != target ||
        session.pouchId.trim().isEmpty) {
      return RestoreResult.none;
    }
    final credential = await readCredential(
      hostPeerId: target,
      pouchId: session.pouchId,
      nowMs: _now().millisecondsSinceEpoch,
    );
    if (credential == null || credential.trim().isEmpty) {
      return RestoreResult.none;
    }
    final peer = await lookupPeer(target);
    if (peer == null) return RestoreResult.none;

    final deadline = _now().add(budget);
    if (!await _connect(peer, deadline)) return RestoreResult.unreachable;
    return renew(hostPeerId: target, session: session, deadline: deadline);
  }

  /// 只做「用凭据换登录态」这一步，不负责连接。
  ///
  /// keeper 是在已经收到主机事件时调用的，那时连接已经有了；冷启动才需要
  /// [run] 里的连接。
  Future<RestoreResult> renew({
    required String hostPeerId,
    PouchSession? session,
    DateTime? deadline,
  }) async {
    final target = hostPeerId.trim();
    final current = session ?? await readSession();
    if (current == null ||
        current.hostPeerId != target ||
        current.pouchId.trim().isEmpty) {
      return RestoreResult.none;
    }
    final credential = await readCredential(
      hostPeerId: target,
      pouchId: current.pouchId,
      nowMs: _now().millisecondsSinceEpoch,
    );
    if (credential == null || credential.trim().isEmpty) {
      return RestoreResult.none;
    }
    final end = deadline ?? _now().add(loginBudget);
    var left = end.difference(_now());
    if (left <= Duration.zero) return RestoreResult.unreachable;
    if (left > loginBudget) left = loginBudget;
    try {
      final grant = await login(
        hostPeerId: target,
        pouchId: current.pouchId,
        credential: credential,
      ).timeout(left);
      await applyLoginGrant(
        session: current,
        grant: grant,
        persist: persist,
        install: install,
        saveCredential: saveCredential,
      );
      log?.call('凭据续期成功：pouch=${current.pouchId}');
      return RestoreResult.restored;
    } on PouchCredentialRejected catch (error) {
      log?.call('设备凭据被拒绝：pouch=${current.pouchId} error=$error');
      await dropCredential(target);
      return RestoreResult.rejected;
    } on TimeoutException {
      log?.call('凭据续期超时：pouch=${current.pouchId}');
      return RestoreResult.unreachable;
    } catch (error) {
      log?.call('凭据续期失败：pouch=${current.pouchId} error=$error');
      return RestoreResult.unreachable;
    }
  }

  /// 两次机会共用同一份预算。第一次超时多半是半开连接，断开再来一次。
  Future<bool> _connect(PairedPeer peer, DateTime deadline) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final left = deadline.difference(_now());
      if (left <= Duration.zero) return false;
      final slice = left < connectBudget ? left : connectBudget;
      try {
        await connect(peer, redial: attempt > 0).timeout(slice);
        return true;
      } catch (_) {
        // 还有一次机会就在下面断开重连。预算用完了就交给调用方。
      }
    }
    return false;
  }
}

/// 接真实服务的那份。Splash、解锁页、keeper 都用同一个。
CredentialRestore productionCredentialRestore({CliHostEndpoint? cli}) {
  return CredentialRestore(
    readSession: PouchSessionStore.readActive,
    lookupPeer: (hostPeerId) =>
        PeerStorageService().getPeerById(hostPeerId),
    readCredential: ({
      required String hostPeerId,
      required String pouchId,
      required int nowMs,
    }) async {
      final saved = await PouchCredentialStore.instance.readValid(
        hostPeerId: hostPeerId,
        pouchId: pouchId,
        nowMs: nowMs,
      );
      return saved?.credential;
    },
    connect: (peer, {required bool redial}) async {
      // 本机主机走 attach：它顺手把地址收回环，老 session 里的旧端口也一起修好。
      final local = cli ?? await CliHost.detect();
      if (local != null && sameFingerprint(local.fingerprint, peer.fingerprint)) {
        await CliHost.attach(local);
        return;
      }
      if (redial) {
        await PeerConnectionManager.instance.disconnectPeer(peer.id);
      }
      await PeerConnectionManager.instance.connectToPeer(
        peer,
        ignoreTieBreak: true,
      );
    },
    login: ({
      required String hostPeerId,
      required String pouchId,
      required String credential,
    }) =>
        requestPouchLogin(
      hostPeerId: hostPeerId,
      pouchId: pouchId,
      credential: credential,
    ),
    persist: (next) async {
      await PouchSessionStore(await PouchSessionStore.appFile()).save(next);
    },
    install: PouchChannel.install,
    saveCredential: ({
      required String hostPeerId,
      required String pouchId,
      required String credential,
      required int expiresAtMs,
    }) =>
        PouchCredentialStore.instance.save(
      hostPeerId: hostPeerId,
      pouchId: pouchId,
      credential: credential,
      expiresAtMs: expiresAtMs,
    ),
    dropCredential: (hostPeerId) =>
        PouchCredentialStore.instance.delete(hostPeerId),
    log: (message) => LoggerService().info(message, tag: 'CredentialRestore'),
  );
}
