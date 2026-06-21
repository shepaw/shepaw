import '../../l10n/app_localizations.dart';

/// 将加入/配对错误码转为用户可读文案。
String mapAccountJoinError(String raw, AppLocalizations l10n) {
  final lower = raw.toLowerCase();
  if (lower.contains('primary_required')) {
    return l10n.qrLogin_errorPrimaryRequired;
  }
  if (lower.contains('timed out') || lower.contains('timeout')) {
    return l10n.qrLogin_errorJoinTimeout;
  }
  if (lower.contains('rejected') || lower.contains('cancelled')) {
    return l10n.qrLogin_errorJoinRejected;
  }
  if (lower.contains('本地服务和 channel') ||
      lower.contains('local server') && lower.contains('channel')) {
    return l10n.qrLogin_errorPairingUnavailable;
  }
  if (lower.contains('peer not connected') || lower.contains('p2p connection')) {
    return l10n.qrLogin_errorPeerConnection;
  }
  return l10n.account_joinFailed(raw);
}

/// 配对启动失败时的提示（展示 QR 侧）。
String mapPairingStartError(String raw, AppLocalizations l10n) {
  final lower = raw.toLowerCase();
  if (lower.contains('本地服务和 channel') ||
      lower.contains('local') && lower.contains('channel')) {
    return l10n.qrLogin_errorPairingUnavailable;
  }
  return l10n.qrLogin_errorPairingStart(raw);
}

/// 展示 QR 前置检查错误。
String mapQrDisplayPreflightError(String code, AppLocalizations l10n) {
  if (code == 'not_primary') {
    return l10n.qrLogin_errorNotPrimary;
  }
  return l10n.qrLogin_displayFailed(code);
}
