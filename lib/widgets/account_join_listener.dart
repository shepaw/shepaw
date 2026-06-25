import 'dart:async';

import 'package:flutter/material.dart';

import '../identity/models/account_join_request.dart';
import '../identity/models/device_role.dart';
import '../identity/services/account_join_service.dart';
import '../l10n/app_localizations.dart';
import '../service_locator.dart';

/// 监听 Primary 设备上的账号加入请求并弹出审批对话框。
class AccountJoinListener extends StatefulWidget {
  final Widget child;

  const AccountJoinListener({super.key, required this.child});

  @override
  State<AccountJoinListener> createState() => _AccountJoinListenerState();
}

class _AccountJoinListenerState extends State<AccountJoinListener> {
  StreamSubscription<AccountJoinPendingRequest>? _sub;
  final _shown = <String>{};

  @override
  void initState() {
    super.initState();
    _sub = AccountJoinService.instance.pendingRequests.listen(_onPending);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onPending(AccountJoinPendingRequest req) {
    if (_shown.contains(req.requestId)) return;
    // 配对确认弹窗关闭后下一帧再弹，避免 Navigator 尚未就绪导致弹窗丢失。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _presentJoinDialog(req);
    });
  }

  void _presentJoinDialog(AccountJoinPendingRequest req, [int attempt = 0]) {
    if (_shown.contains(req.requestId)) return;
    if (attempt > 30) return;

    final ctx = navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _presentJoinDialog(req, attempt + 1),
      );
      return;
    }

    _shown.add(req.requestId);
    final l10n = AppLocalizations.of(ctx);
    showDialog<void>(
      context: ctx,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        title: Text(l10n.account_joinDialogTitle),
        content: Text(l10n.account_joinDialogBody(req.deviceName, _roleLabel(req.preferredRole, l10n))),
        actions: [
          TextButton(
            onPressed: () async {
              await AccountJoinService.instance.rejectJoin(req.requestId);
              if (dialogCtx.mounted) Navigator.pop(dialogCtx);
            },
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () async {
              try {
                await AccountJoinService.instance.approveJoin(req.requestId);
                if (dialogCtx.mounted) {
                  Navigator.pop(dialogCtx);
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text(l10n.account_joinApproved(req.deviceName))),
                  );
                }
              } catch (e) {
                if (dialogCtx.mounted) {
                  Navigator.pop(dialogCtx);
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text(l10n.account_joinApproveFailed(e.toString()))),
                  );
                }
              }
            },
            child: Text(l10n.account_joinApprove),
          ),
        ],
      ),
    );
  }

  String _roleLabel(DeviceRole role, AppLocalizations l10n) {
    switch (role) {
      case DeviceRole.primary:
        return l10n.identity_rolePrimary;
      case DeviceRole.backup:
        return l10n.identity_roleBackup;
      case DeviceRole.app:
        return l10n.identity_roleApp;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
