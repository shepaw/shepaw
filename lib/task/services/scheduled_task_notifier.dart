import '../../services/app_lifecycle_service.dart';
import '../../services/chat_navigation_service.dart';
import '../../services/logger_service.dart';
import '../../services/notification_service.dart';
import '../models/scheduled_task.dart';

/// Local notifications for scheduled **group** tasks (fire / fail).
///
/// Approvals still go through [PendingApprovalHub] +
/// [ApprovalReachabilityNotifier] once the headless interaction is persisted.
class ScheduledTaskNotifier {
  ScheduledTaskNotifier._();

  static const payloadPrefix = 'scheduled_task:';
  static const _tag = 'ScheduledTaskNotify';

  static bool _tapHandlerRegistered = false;

  static void ensureInitialized() {
    if (_tapHandlerRegistered) return;
    NotificationService().addNotificationTapHandler(_onTap);
    _tapHandlerRegistered = true;
  }

  /// Channel id encoded in a notification payload, if any.
  static String? channelIdFromPayload(String? payload) {
    if (payload == null || !payload.startsWith(payloadPrefix)) return null;
    final id = payload.substring(payloadPrefix.length);
    return id.isEmpty ? null : id;
  }

  static Future<void> notifyFired({
    required ScheduledTask task,
    required String groupName,
  }) async {
    final channelId = task.channelId;
    if (channelId == null || channelId.isEmpty) return;
    if (AppLifecycleService().shouldSuppressNotification(channelId)) return;

    final title = groupName.trim().isNotEmpty ? groupName.trim() : '定时任务';
    final body = task.description.trim().isNotEmpty
        ? '定时任务已触发：${task.description.trim()}'
        : '定时任务已在群聊触发';
    await _show(
      id: _notifId('${task.id}:fired'),
      title: title,
      body: body,
      payload: '$payloadPrefix$channelId',
    );
  }

  static Future<void> notifyFailed({
    required ScheduledTask task,
    required Object error,
    String groupName = '',
  }) async {
    final channelId = task.channelId;
    if (channelId == null || channelId.isEmpty) return;
    if (AppLifecycleService().shouldSuppressNotification(channelId)) return;

    final title = groupName.trim().isNotEmpty ? groupName.trim() : '定时任务';
    var detail = error.toString();
    if (detail.length > 80) detail = '${detail.substring(0, 80)}…';
    await _show(
      id: _notifId('${task.id}:failed'),
      title: title,
      body: '定时任务执行失败：$detail',
      payload: '$payloadPrefix$channelId',
    );
  }

  static Future<void> _show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    await NotificationService().showNotification(
      id: id,
      title: title,
      body: body,
      payload: payload,
    );
    LoggerService().info('Scheduled task notice: $title / $body', tag: _tag);
  }

  static void _onTap(String? payload) {
    final channelId = channelIdFromPayload(payload);
    if (channelId == null) return;
    ChatNavigationService.instance.openChannel(channelId: channelId);
  }

  static int _notifId(String key) => key.hashCode & 0x7fffffff;
}
