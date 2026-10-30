import 'chat_navigation_service.dart';
import 'logger_service.dart';
import 'notification_service.dart';

/// 普通聊天消息通知的点击处理。
///
/// 之前消息通知不带 payload（见 ChatService._maybeShowNotification），点了
/// 没有反应。这里按定时任务通知同样的做法：payload 里带上频道 id，点击后
/// 交给 [ChatNavigationService] 打开会话（未登录时它自己会拦到登录页）。
class ChatMessageNotification {
  ChatMessageNotification._();

  static const payloadPrefix = 'chat:';

  static const _tag = 'ChatMessageNotify';

  static bool _tapHandlerRegistered = false;

  static void ensureInitialized() {
    if (_tapHandlerRegistered) return;
    NotificationService().addNotificationTapHandler(_onTap);
    _tapHandlerRegistered = true;
  }

  /// 通知 payload 里编码的频道 id，不是本类发的通知则返回 null。
  static String? channelIdFromPayload(String? payload) {
    if (payload == null || !payload.startsWith(payloadPrefix)) return null;
    final id = payload.substring(payloadPrefix.length);
    return id.isEmpty ? null : id;
  }

  static String payloadFor(String channelId) => '$payloadPrefix$channelId';

  static void _onTap(String? payload) {
    final channelId = channelIdFromPayload(payload);
    if (channelId == null) return;
    LoggerService().info('Chat notice tapped: $channelId', tag: _tag);
    ChatNavigationService.instance.openChannel(channelId: channelId);
  }
}
