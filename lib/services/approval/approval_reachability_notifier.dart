import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/notification_provider.dart';
import '../app_lifecycle_service.dart';
import '../chat_navigation_service.dart';
import '../logger_service.dart';
import '../notification_service.dart';
import 'pending_approval_hub.dart';
import 'pending_approval_item.dart';

/// Watches [PendingApprovalHub] and fires system notifications when the user
/// is outside the app.
///
/// Each approval id is notified **at most once** until it is resolved, so
/// opening the chat / refreshing metadata / peer resend cannot re-spam.
class ApprovalReachabilityNotifier {
  ApprovalReachabilityNotifier._();
  static final ApprovalReachabilityNotifier instance =
      ApprovalReachabilityNotifier._();

  static const payloadPrefix = 'approval:';
  static const _tag = 'ApprovalReachNotify';

  GlobalKey<NavigatorState>? _navigatorKey;
  StreamSubscription<List<PendingApprovalItem>>? _hubSub;
  StreamSubscription<String?>? _channelSub;
  bool _tapHandlerRegistered = false;

  /// Ids we have already surfaced via a system notification (or suppressed
  /// after the user opened that channel). Cleared only when the hub resolves.
  final Set<String> _notifiedIds = {};

  void init({GlobalKey<NavigatorState>? navigatorKey}) {
    _navigatorKey = navigatorKey;
    if (!_tapHandlerRegistered) {
      NotificationService().addNotificationTapHandler(_onTap);
      _tapHandlerRegistered = true;
    }
    _hubSub ??= PendingApprovalHub.instance.stream.listen(_onHubUpdate);
    _channelSub ??=
        AppLifecycleService().onActiveChannelChanged.listen((_) {
      _onActiveChannelChanged();
    });
    LoggerService().info('ApprovalReachabilityNotifier started', tag: _tag);
  }

  Future<void> dispose() async {
    await _hubSub?.cancel();
    _hubSub = null;
    await _channelSub?.cancel();
    _channelSub = null;
  }

  /// Test helper.
  void resetForTest() {
    _notifiedIds.clear();
  }

  void _onHubUpdate(List<PendingApprovalItem> items) {
    final currentIds = items.map((i) => i.id).toSet();
    // Drop tracking for resolved approvals so a future re-created id can notify.
    _notifiedIds.removeWhere((id) => !currentIds.contains(id));

    for (final item in items) {
      unawaited(_maybeNotify(item));
    }
  }

  Future<void> _maybeNotify(PendingApprovalItem item) async {
    // Already surfaced once for this pending id — never re-alert until resolve.
    if (_notifiedIds.contains(item.id)) return;

    final lifecycle = AppLifecycleService();
    // Foreground: rely on banner + list badge only.
    if (lifecycle.isInForeground) return;

    // Claim before the async show so concurrent hub emits cannot double-fire.
    _notifiedIds.add(item.id);

    final ctx = _navigatorKey?.currentContext;
    NotificationProvider? provider;
    if (ctx != null) {
      try {
        provider = Provider.of<NotificationProvider>(ctx, listen: false);
      } catch (_) {}
    }
    if (provider != null &&
        item.agentId.isNotEmpty &&
        !provider.shouldNotify(item.agentId)) {
      return;
    }

    final l10n = ctx != null ? AppLocalizations.of(ctx) : null;
    final title = item.agentName.isNotEmpty
        ? item.agentName
        : (l10n?.approval_needsReviewTitle ?? 'Needs review');
    final body = l10n != null
        ? (item.kind == PendingApprovalKind.plan
            ? l10n.approval_needsPlanReview
            : l10n.approval_needsActionReview)
        : (item.kind == PendingApprovalKind.plan
            ? 'Plan awaiting your approval'
            : 'Action awaiting your approval');

    final mid = item.messageId ?? '';
    await NotificationService().showNotification(
      id: _notifId(item.id),
      title: title,
      body: body,
      playSound: provider?.soundEnabled ?? true,
      payload: '$payloadPrefix${item.channelId}:$mid',
      channel: NotificationService.approvalsChannelId,
    );
    LoggerService().info('Notified approval ${item.id}', tag: _tag);
  }

  /// Viewing the approval channel: clear the OS shade entry, but keep the id
  /// in [_notifiedIds] so leaving/backgrounding cannot re-spam the same item.
  void _onActiveChannelChanged() {
    final active = AppLifecycleService().activeChannelId;
    if (active == null) return;
    for (final item in PendingApprovalHub.instance.itemsForChannel(active)) {
      _notifiedIds.add(item.id);
      unawaited(NotificationService().cancelNotification(_notifId(item.id)));
    }
  }

  void _onTap(String? payload) {
    if (payload == null || !payload.startsWith(payloadPrefix)) return;
    final rest = payload.substring(payloadPrefix.length);
    final colon = rest.indexOf(':');
    final channelId = colon < 0 ? rest : rest.substring(0, colon);
    final messageId = colon < 0 ? null : rest.substring(colon + 1);
    if (channelId.isEmpty) return;
    final mid = (messageId == null || messageId.isEmpty) ? null : messageId;
    unawaited(
      ChatNavigationService.instance.openChannel(
        channelId: channelId,
        messageId: mid,
      ),
    );
  }

  static int _notifId(String id) => id.hashCode & 0x7fffffff;
}
