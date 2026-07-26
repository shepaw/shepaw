import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../screens/storage_space_screen.dart';
import '../services/logger_service.dart';
import '../services/notification_service.dart';
import 'import_auth_service.dart';

/// 路径 A：旧设备/master 收到新 `import.request` 时发系统通知，点击打开存储页。
class ImportRequestNotifier {
  ImportRequestNotifier._();
  static final ImportRequestNotifier instance = ImportRequestNotifier._();

  static const payloadPrefix = 'storage_import:';
  static const _tag = 'ImportRequestNotify';

  final _log = LoggerService();
  GlobalKey<NavigatorState>? _navigatorKey;
  StreamSubscription<ImportRequest>? _sub;
  bool _tapHandlerRegistered = false;

  /// 在 [NotificationService.init] 之后调用。
  void init({GlobalKey<NavigatorState>? navigatorKey}) {
    _navigatorKey = navigatorKey;
    if (!_tapHandlerRegistered) {
      NotificationService().addNotificationTapHandler(_onTap);
      _tapHandlerRegistered = true;
    }
    _sub ??= ImportRequestBus.instance.onCreated.listen(_onCreated);
    _log.info('ImportRequestNotifier started', tag: _tag);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }

  void _onCreated(ImportRequest req) {
    unawaited(_show(req));
  }

  Future<void> _show(ImportRequest req) async {
    final ctx = _navigatorKey?.currentContext;
    final l10n = ctx != null ? AppLocalizations.of(ctx) : null;
    final short = req.newDevice.length >= 8
        ? '${req.newDevice.substring(0, 8)}…'
        : req.newDevice;
    final title = l10n?.storage_importRequestNotifyTitle ?? 'Import request';
    final body =
        l10n?.storage_importRequestNotifyBody(short) ?? 'From device $short';
    await NotificationService().showNotification(
      id: req.requestId.hashCode & 0x7fffffff,
      title: title,
      body: body,
      payload: '$payloadPrefix${req.requestId}',
    );
    _log.info('notified import request ${req.requestId}', tag: _tag);
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
