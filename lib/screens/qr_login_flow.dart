import 'package:flutter/material.dart';

import '../identity/models/account_join_result.dart';
import '../identity/models/device_role.dart';
import '../identity/services/account_join_errors.dart';
import '../identity/services/account_join_service.dart';
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
    final progress = ValueNotifier<String>(l10n.account_joinWaitingApproval);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<String>(
        valueListenable: progress,
        builder: (ctx, message, __) => AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );

    AccountJoinResult? result;
    try {
      AccountJoinService.instance.start();
      result = await AccountJoinService.instance.joinViaPeer(
        peer: peer,
        preferredRole: preferredRole,
        onProgress: (phase) {
          switch (phase) {
            case AccountJoinProgress.waitingApproval:
              progress.value = l10n.account_joinWaitingApproval;
            case AccountJoinProgress.connectingAccount:
              progress.value = l10n.qrLogin_connectingAccount;
            case AccountJoinProgress.syncing:
              progress.value = l10n.qrLogin_syncing;
          }
        },
      );

      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      if (fromHome) {
        _showJoinResultSnackbar(context, l10n, result);
        return;
      }

      final isPasswordSet = await PasswordService().isPasswordSet();
      if (!context.mounted) return;

      if (isPasswordSet) {
        Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
      } else {
        Navigator.of(context).pushNamedAndRemoveUntil('/setup', (_) => false);
      }

      if (context.mounted) {
        _showJoinResultSnackbar(context, l10n, result);
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mapAccountJoinError(e.toString(), l10n))),
        );
      }
    } finally {
      progress.dispose();
    }
  }

  static void _showJoinResultSnackbar(
    BuildContext context,
    AppLocalizations l10n,
    AccountJoinResult result,
  ) {
    if (result.syncSucceeded) {
      final msg = result.reconnected ? l10n.qrLogin_reconnected : l10n.qrLogin_joinSuccess;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.qrLogin_syncFailed(result.syncError ?? '')),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }
}
