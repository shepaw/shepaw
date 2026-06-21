import 'package:flutter/material.dart';

import '../identity/models/device_role.dart';
import '../identity/services/account_join_service.dart';
import '../identity/services/account_session_service.dart';
import '../l10n/app_localizations.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_qr_scanner_screen.dart';
import '../services/password_service.dart';

/// 扫码登录：扫描主存储设备 QR → 加入同一账号 → 同步。
class QrLoginFlow {
  QrLoginFlow._();

  /// 打开相机扫描并完成账号加入。
  ///
  /// [fromHome] 为 true 时假定已在本机登录，成功后仅提示并返回，不重置导航栈。
  static Future<void> scanAndJoin(
    BuildContext context, {
    DeviceRole preferredRole = DeviceRole.app,
    bool fromHome = false,
  }) async {
    final peer = await Navigator.push<PairedPeer>(
      context,
      MaterialPageRoute(
        builder: (ctx) => PeerQrScannerScreen(
          onPaired: (p) => Navigator.pop(ctx, p),
        ),
      ),
    );
    if (peer == null || !context.mounted) return;

    await joinWithPeer(
      context,
      peer: peer,
      preferredRole: preferredRole,
      fromHome: fromHome,
    );
  }

  static Future<void> joinWithPeer(
    BuildContext context, {
    required PairedPeer peer,
    DeviceRole preferredRole = DeviceRole.app,
    bool fromHome = false,
  }) async {
    final l10n = AppLocalizations.of(context);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(child: Text(l10n.account_joinWaitingApproval)),
          ],
        ),
      ),
    );

    try {
      AccountJoinService.instance.start();
      await AccountJoinService.instance.joinViaPeer(
        peer: peer,
        preferredRole: preferredRole,
      );
      AccountSessionService.instance.resetSyncState();
      await AccountSessionService.instance.activate();

      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      if (fromHome) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.qrLogin_joinSuccess)),
        );
        return;
      }

      final isPasswordSet = await PasswordService().isPasswordSet();
      if (!context.mounted) return;
      if (isPasswordSet) {
        Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
      } else {
        Navigator.of(context).pushNamedAndRemoveUntil('/setup', (_) => false);
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.account_joinFailed(e.toString()))),
        );
      }
    }
  }
}
