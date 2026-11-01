import 'pouch_login_client.dart';
import 'pouch_session.dart';

/// 把一次成功的登录态装到本进程。
///
/// keeper 收到 `pouch_login_required` 时的重新登录、和冷启动的静默续期，
/// 用的是同一段：换 session → 装通道 → 存新凭据。两边不能各写一份，否则
/// 凭据轮换的规则迟早会对不上。
Future<PouchSession> applyLoginGrant({
  required PouchSession session,
  required PouchLoginGrant grant,
  required Future<void> Function(PouchSession session) persist,
  required void Function(PouchSession session) install,
  required Future<void> Function({
    required String hostPeerId,
    required String pouchId,
    required String credential,
    required int expiresAtMs,
  }) saveCredential,
}) async {
  final next = PouchSession(
    hubUrl: session.hubUrl,
    pouchId: session.pouchId,
    pouchName: session.pouchName,
    hostPeerId: session.hostPeerId,
    token: grant.token,
    sessionId: grant.sessionId,
    expiresAtMs: grant.expiresAtMs,
  );
  await persist(next);
  install(next);
  // 密码登录会换发新凭据；凭据登录不轮换，这里就没有新值。
  final issued = grant.credential?.trim() ?? '';
  if (issued.isNotEmpty) {
    await saveCredential(
      hostPeerId: next.hostPeerId,
      pouchId: next.pouchId,
      credential: issued,
      expiresAtMs: grant.credentialExpiresAtMs,
    );
  }
  return next;
}
