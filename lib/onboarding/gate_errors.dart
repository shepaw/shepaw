import 'dart:async';

import '../l10n/app_localizations.dart';
import '../storage/pouch_login_client.dart';

/// 一次登录失败。
///
/// 门页上**不允许**把 `'$error'`、`error.toString()` 直接放进 Text：那会把
/// `StateError: 没有这只袋子`、`TimeoutException after 0:00:15` 摆到用户面前。
/// 这里只留「发生了什么」和「要等多久」，原始错误进 [detail]，只给日志和
/// `GateStatusCard` 的折叠「详情」用。显示什么由 [gateErrorTitle] 决定。
class GateError {
  const GateError({required this.kind, this.detail, this.retryAfter});

  final GateErrorKind kind;

  /// 原始错误。只给日志和「详情」折叠区。
  final String? detail;

  /// 主机要求等多久。非空时主按钮变成倒计时。
  final Duration? retryAfter;

  bool get locked => retryAfter != null;
}

enum GateErrorKind {
  /// 密码不对。
  wrongPassword,

  /// 试错太多次，主机在限流。
  locked,

  /// 设备凭据被拒。不当错误显示，转成解锁页顶部的原因条。
  credentialRejected,

  /// 加入码失效。
  inviteInvalid,

  /// 主机上找不到这只袋子。
  pouchMissing,

  /// 主机的密码文件丢了或坏了。
  passwordFileBroken,

  /// 这台主机已经初始化过了（别处刚设过密码）。
  alreadyInitialized,

  /// 连不上主机。
  unreachable,

  /// 主机版本太旧。
  hostOutdated,

  /// 其他。
  unknown,
}

/// 把一次登录失败归类。纯函数，不碰文案。
///
/// 新主机回稳定的 `code`，老主机只回中文 `reason`，两条路都要能走通：
/// C2 上线后 `code` 是主路径，按 reason 兜底是给老主机留的。
GateError mapGateError(Object error) {
  final detail = error.toString();
  if (error is PouchCredentialRejected) {
    return GateError(kind: GateErrorKind.credentialRejected, detail: detail);
  }
  if (error is PouchLoginRejected) {
    final code = error.code;
    if (code == 'locked' || error.retryAfter != null) {
      return GateError(
        kind: GateErrorKind.locked,
        detail: detail,
        retryAfter: error.retryAfter,
      );
    }
    if (code == 'invite_invalid') {
      return GateError(kind: GateErrorKind.inviteInvalid, detail: detail);
    }
    if (code == 'pouch_missing' || error.reason.contains('没有这只袋子')) {
      return GateError(kind: GateErrorKind.pouchMissing, detail: detail);
    }
    if (code == 'password_file_broken' ||
        error.reason.contains('口令文件丢失') ||
        error.reason.contains('密码文件损坏')) {
      return GateError(kind: GateErrorKind.passwordFileBroken, detail: detail);
    }
    if (code == 'wrong_password' || error.reason.contains('密码不对')) {
      return GateError(kind: GateErrorKind.wrongPassword, detail: detail);
    }
    return GateError(kind: GateErrorKind.unknown, detail: detail);
  }
  if (error is TimeoutException) {
    return GateError(kind: GateErrorKind.unreachable, detail: detail);
  }
  if (detail.contains('没有这只袋子')) {
    return GateError(kind: GateErrorKind.pouchMissing, detail: detail);
  }
  if (detail.contains('口令文件丢失') || detail.contains('密码文件损坏')) {
    return GateError(kind: GateErrorKind.passwordFileBroken, detail: detail);
  }
  if (detail.contains('已经初始化过了')) {
    return GateError(kind: GateErrorKind.alreadyInitialized, detail: detail);
  }
  if (detail.contains('旧版本')) {
    return GateError(kind: GateErrorKind.hostOutdated, detail: detail);
  }
  return GateError(kind: GateErrorKind.unknown, detail: detail);
}

/// [GateError] 显示什么。
String gateErrorTitle(AppLocalizations l10n, GateError error) {
  switch (error.kind) {
    case GateErrorKind.wrongPassword:
      return l10n.unlock_wrongPassword;
    case GateErrorKind.locked:
      return l10n.unlock_tooManyAttempts;
    case GateErrorKind.inviteInvalid:
      return l10n.gate_errorInvite;
    case GateErrorKind.pouchMissing:
      return l10n.gate_errorPouchMissing;
    case GateErrorKind.passwordFileBroken:
      return l10n.gate_errorPasswordFile;
    case GateErrorKind.unreachable:
      return l10n.gate_errorUnreachable;
    case GateErrorKind.hostOutdated:
      return l10n.gate_errorHostOutdated;
    case GateErrorKind.credentialRejected:
    case GateErrorKind.alreadyInitialized:
    case GateErrorKind.unknown:
      return l10n.gate_errorGeneric;
  }
}
