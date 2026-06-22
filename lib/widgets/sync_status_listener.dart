import 'dart:async';

import 'package:flutter/material.dart';

import '../identity/services/sync_client_service.dart';
import '../l10n/app_localizations.dart';
import '../service_locator.dart';

/// 监听同步状态（如 stale commit）并向用户展示轻量提示。
class SyncStatusListener extends StatefulWidget {
  final Widget child;

  const SyncStatusListener({super.key, required this.child});

  @override
  State<SyncStatusListener> createState() => _SyncStatusListenerState();
}

class _SyncStatusListenerState extends State<SyncStatusListener> {
  StreamSubscription<void>? _staleSub;

  @override
  void initState() {
    super.initState();
    _staleSub = SyncClientService.instance.staleCommitEvents.listen((_) {
      _showStaleCommitNotice();
    });
  }

  @override
  void dispose() {
    _staleSub?.cancel();
    super.dispose();
  }

  void _showStaleCommitNotice() {
    final ctx = navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final l10n = AppLocalizations.of(ctx);
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(content: Text(l10n.identity_syncStaleCommit)),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
