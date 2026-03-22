import 'package:intl/intl.dart';
import '../models/message.dart';

/// 消息工具类
class MessageUtils {
  /// 按日期分组消息
  static Map<DateTime, List<Message>> groupMessagesByDate(List<Message> messages) {
    final Map<DateTime, List<Message>> grouped = {};
    
    for (final message in messages) {
      // 只使用日期部分（忽略时间）
      final date = DateTime(
        message.dateTime.year,
        message.dateTime.month,
        message.dateTime.day,
      );
      
      if (!grouped.containsKey(date)) {
        grouped[date] = [];
      }
      
      grouped[date]!.add(message);
    }
    
    return grouped;
  }

  /// 获取日期显示文本
  static String getDateDisplayText(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    
    final messageDate = DateTime(date.year, date.month, date.day);
    
    if (messageDate == today) {
      return 'Today';
    } else if (messageDate == yesterday) {
      return 'Yesterday';
    } else {
      return DateFormat('MMMM d, yyyy').format(date);
    }
  }

  /// 判断是否显示日期分隔符
  static bool shouldShowDateSeparator(Message? previousMessage, Message currentMessage) {
    if (previousMessage == null) return true;
    
    final previousDate = DateTime(
      previousMessage.dateTime.year,
      previousMessage.dateTime.month,
      previousMessage.dateTime.day,
    );
    
    final currentDate = DateTime(
      currentMessage.dateTime.year,
      currentMessage.dateTime.month,
      currentMessage.dateTime.day,
    );
    
    return previousDate != currentDate;
  }

  /// 判断是否显示时间戳
  static bool shouldShowTimestamp(Message? previousMessage, Message currentMessage) {
    if (previousMessage == null) return true;
    
    // 如果是不同的发送者，显示时间戳
    if (previousMessage.senderId != currentMessage.senderId) {
      return true;
    }
    
    // 如果时间间隔超过5分钟，显示时间戳
    final timeDiff = currentMessage.timestamp.difference(previousMessage.timestamp);
    return timeDiff.inMinutes > 5;
  }

  /// 判断是否连续消息（不显示头像和时间）
  static bool isConsecutiveMessage(Message? previousMessage, Message currentMessage) {
    if (previousMessage == null) return false;
    
    // 相同发送者
    if (previousMessage.senderId != currentMessage.senderId) {
      return false;
    }
    
    // 时间间隔小于2分钟
    final timeDiff = currentMessage.timestamp.difference(previousMessage.timestamp);
    if (timeDiff.inMinutes > 2) {
      return false;
    }
    
    return true;
  }

  /// 编辑消息
  static Message editMessage(Message originalMessage, String newContent) {
    return Message(
      id: originalMessage.id,
      from: originalMessage.from,
      to: originalMessage.to,
      channelId: originalMessage.channelId,
      type: originalMessage.type,
      content: newContent,
      timestampMs: originalMessage.timestampMs,
      replyTo: originalMessage.replyTo,
      metadata: {
        ...?originalMessage.metadata,
        'edited': true,
        'edited_at': DateTime.now().millisecondsSinceEpoch,
        'original_content': originalMessage.content,
      },
    );
  }

  /// 检查消息是否已被编辑
  static bool isMessageEdited(Message message) {
    return message.metadata?['edited'] == true;
  }

  /// 获取编辑时间
  static String getEditedTimeText(Message message) {
    final editedAt = message.metadata?['edited_at'];
    if (editedAt == null) return '';
    
    final editedDateTime = DateTime.fromMillisecondsSinceEpoch(editedAt);
    return 'edited ${DateFormat('HH:mm').format(editedDateTime)}';
  }

  /// 消息摘要（用于通知或预览）
  static String getMessageSummary(Message message, {int maxLength = 50}) {
    String summary = message.content;
    
    if (message.type == MessageType.image) {
      summary = '📷 Image';
    } else if (message.type == MessageType.file) {
      if (message.metadata != null && message.metadata!['name'] != null) {
        summary = '📎 ${message.metadata!['name']}';
      } else {
        summary = '📎 File';
      }
    }
    
    if (summary.length > maxLength) {
      summary = '${summary.substring(0, maxLength)}...';
    }
    
    return summary;
  }

  /// 验证消息内容
  static bool isValidMessageContent(String content) {
    return content.trim().isNotEmpty && content.length <= 10000;
  }

  /// 格式化消息时间
  static String formatMessageTime(Message message) {
    final now = DateTime.now();
    final messageTime = message.dateTime;
    
    // 今天
    if (messageTime.year == now.year && 
        messageTime.month == now.month && 
        messageTime.day == now.day) {
      return DateFormat('HH:mm').format(messageTime);
    }
    
    // 昨天
    final yesterday = now.subtract(const Duration(days: 1));
    if (messageTime.year == yesterday.year && 
        messageTime.month == yesterday.month && 
        messageTime.day == yesterday.day) {
      return 'Yesterday ${DateFormat('HH:mm').format(messageTime)}';
    }
    
    // 更早
    return DateFormat('MM/dd HH:mm').format(messageTime);
  }

  /// 检查消息是否可以被编辑
  static bool canEditMessage(Message message, String currentUserId, {Duration maxAge = const Duration(hours: 24)}) {
    // 只能编辑自己的消息
    if (message.senderId != currentUserId) {
      return false;
    }
    
    // 不能编辑系统消息
    if (message.type == MessageType.system) {
      return false;
    }
    
    // 消息太旧不能编辑
    final age = DateTime.now().difference(message.timestamp);
    if (age > maxAge) {
      return false;
    }
    
    return true;
  }

  /// 检查消息是否可以被删除
  static bool canDeleteMessage(Message message, String currentUserId) {
    // 可以删除自己的消息
    if (message.senderId == currentUserId) {
      return true;
    }
    
    // 系统消息可以删除
    if (message.type == MessageType.system) {
      return true;
    }
    
    return false;
  }

  /// 获取消息类型图标
  static String getMessageTypeIcon(Message message) {
    switch (message.type) {
      case MessageType.image:
        return '📷';
      case MessageType.file:
        return '📎';
      case MessageType.system:
        return 'ℹ️';
      case MessageType.text:
      default:
        return '';
    }
  }

  /// 检查消息是否包含关键词
  static bool containsKeyword(Message message, String keyword) {
    if (keyword.isEmpty) return true;
    return message.content.toLowerCase().contains(keyword.toLowerCase());
  }
}
