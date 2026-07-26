import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../screens/storage_space_screen.dart';
import '../services/logger_service.dart';
import '../services/notification_service.dart';
import 'import_auth_service.dart';

/// 新设备收到 `import.grant` 推送时发系统通知，点击打开存储页浏览导入。
class ImportGrantNotifier {
  ImportGrantNotifier._();
  static final ImportGrantNotifier instance = ImportGrantNotifier._();

  static const payloadPrefix = 'storage_grant:';
  static const _tag = 'ImportGrantNotify';

  final _log = LoggerService();
  GlobalKey<NavigatorState>? _navigatorKey;
  StreamSubscription<ImportGrant>? _sub;
  bool _tapHandlerRegistered = false;

  /// 在 [NotificationService.init] 之后调用。
  void init({GlobalKey<NavigatorState>? navigatorKey}) {
    _navigatorKey = navigatorKey;
    if (!_tapHandlerRegistered) {
      NotificationService().addNotificationTapHandler(_onTap);
      _tapHandlerRegistered = true;
    }
    _sub ??= ImportGrantBus.instance.onReceived.listen(_onReceived);
    _log.info('ImportGrantNotifier started', tag: _tag);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }

  void _onReceived(ImportGrant grant) {
    unawaited(_show(grant));
  }

  Future<void> _show(ImportGrant grant) async {
    final ctx = _navigatorKey?.currentContext;
    final l10n = ctx != null ? AppLocalizations.of(ctx) : null;
    final short = grant.oldDevice.length >= 8
        ? '${grant.oldDevice.substring(0, 8)}…'
        : grant.oldDevice;
    final title = l10n?.storage_importGrantNotifyTitle ?? 'Import authorized';
    final body =
        l10n?.storage_importGrantNotifyBody(short) ?? 'From device $short';
    await NotificationService().showNotification(
      id: grant.grantId.hashCode & 0x7fffffff,
      title: title,
      body: body,
      payload: '$payloadPrefix${grant.grantId}',
    );
    _log.info('notified import grant ${grant.grantId}', tag: _tag);
  }

  void _onTap(String? payload) {
    if (payload == null || !payload.startsWith(payloadPrefix)) return;
    final nav = _navigatorKey?.currentState;
    if (nav == null) return;
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => const StorageSpaceScreen(),
      ),
    );
  }
}
