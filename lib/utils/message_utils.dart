import 'dart:convert';

import 'package:intl/intl.dart';
import '../models/message.dart';
import '../services/messaging/chat_history_content.dart';
import '../services/she_service.dart';

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

  /// 列表展示顺序：修正时间戳异常造成的错序。
  ///
  /// 时间戳并不总是可靠的排序依据——重连续传会复用上一回合的流式占位
  /// （沿用旧 `created_at`）、peer 历史同步回灌的行可能锚在过期的
  /// `sessionUpdatedAt` 上。结果就是「正在回复」的气泡被排到被回复消息
  /// 之前，甚至整列最上方。
  ///
  /// 两条规则（仅影响展示顺序，不改动 [messages] 本身）：
  /// 1. 回复消息（[Message.replyTo]）绝不排在被回复的消息之前；
  /// 2. 在途流式气泡（[streamingIds]）天然是最新的一条，排在最末。
  ///
  /// 顺序本就正确时直接返回同一个 [messages] 实例，便于调用方复用缓存。
  static List<Message> orderForDisplay(
    List<Message> messages, {
    Set<String> streamingIds = const {},
  }) {
    if (messages.length < 2) return messages;

    final byId = <String, Message>{};
    for (final m in messages) {
      byId.putIfAbsent(m.id, () => m);
    }

    final effective = <String, int>{};
    final visiting = <String>{};
    int resolve(Message m) {
      final cached = effective[m.id];
      if (cached != null) return cached;
      var ts = m.timestampMs;
      final parentId = m.replyTo;
      // visiting 同时充当环守卫：replyTo 成环时直接用自己的时间戳。
      if (parentId != null && visiting.add(m.id)) {
        final parent = byId[parentId];
        if (parent != null) {
          final parentTs = resolve(parent);
          if (ts <= parentTs) ts = parentTs + 1;
        }
        visiting.remove(m.id);
      }
      effective[m.id] = ts;
      return ts;
    }

    final values = <int>[for (final m in messages) resolve(m)];

    if (streamingIds.isNotEmpty) {
      var maxOther = -1;
      for (var i = 0; i < messages.length; i++) {
        if (streamingIds.contains(messages[i].id)) continue;
        if (values[i] > maxOther) maxOther = values[i];
      }
      if (maxOther >= 0) {
        for (var i = 0; i < messages.length; i++) {
          if (!streamingIds.contains(messages[i].id)) continue;
          if (values[i] < maxOther) values[i] = maxOther + 1;
        }
      }
    }

    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      if (values[i] != messages[i].timestampMs) {
        changed = true;
        break;
      }
    }
    if (!changed) return messages;

    final order = List<int>.generate(messages.length, (i) => i);
    order.sort((a, b) {
      final cmp = values[a].compareTo(values[b]);
      return cmp != 0 ? cmp : a.compareTo(b);
    });
    return [for (final i in order) messages[i]];
  }

  /// 反向列表中 [displayIndex] 对应的消息 id。0 是最新一条。
  static String? messageIdAtDisplayIndex(
    List<Message> messages,
    int displayIndex, {
    Set<String> streamingIds = const {},
  }) {
    if (displayIndex < 0) return null;
    final ordered = orderForDisplay(messages, streamingIds: streamingIds);
    final chrono = ordered.length - 1 - displayIndex;
    if (chrono < 0 || chrono >= ordered.length) return null;
    return ordered[chrono].id;
  }

  /// 反向列表中 [id] 的展示下标。找不到返回 -1。
  static int displayIndexOf(
    List<Message> messages,
    String id, {
    Set<String> streamingIds = const {},
  }) {
    final ordered = orderForDisplay(messages, streamingIds: streamingIds);
    for (var i = 0; i < ordered.length; i++) {
      if (ordered[i].id == id) return ordered.length - 1 - i;
    }
    return -1;
  }

  /// 当前窗口与刚从数据库读出的窗口是否是同一批展示内容。
  ///
  /// 用于跳过「同步写完库再整表替换」：内容、顺序、时间戳和 metadata
  /// 都没变时，替换只会让每条气泡丢掉已解析的 Markdown。
  static bool sameDisplayWindow(List<Message> current, List<Message> incoming) {
    if (identical(current, incoming)) return true;
    if (current.length != incoming.length) return false;
    for (var i = 0; i < current.length; i++) {
      final a = current[i];
      final b = incoming[i];
      if (a.id != b.id ||
          a.content != b.content ||
          a.timestampMs != b.timestampMs ||
          a.replyTo != b.replyTo ||
          a.type != b.type) {
        return false;
      }
      if (_metadataJson(a.metadata) != _metadataJson(b.metadata)) return false;
    }
    return true;
  }

  static String _metadataJson(Map<String, dynamic>? metadata) {
    if (metadata == null || metadata.isEmpty) return '';
    try {
      return jsonEncode(metadata);
    } catch (_) {
      return '';
    }
  }

  /// 群聊中是否折叠头像/作者名。
  ///
  /// 已禁用连续同作者折叠：每条群消息独立展示头像与作者栏。
  static bool shouldCollapseSenderChrome({
    required bool isGroupMode,
    required Message? previousMessage,
    required Message currentMessage,
    required bool showDateSeparator,
  }) {
    return false;
  }

  /// 是否显示作者名：仅群聊、非己方。
  static bool shouldShowSenderName({
    required bool isGroupMode,
    required bool isMyMessage,
    required bool collapseSenderChrome,
  }) {
    return isGroupMode && !isMyMessage && !collapseSenderChrome;
  }

  /// 是否绘制头像：仅群聊。
  /// 单聊不显示头像，以增加气泡可用宽度。
  static bool shouldShowAvatar({
    required bool isGroupMode,
    required bool collapseSenderChrome,
  }) {
    if (!isGroupMode) return false;
    return !collapseSenderChrome;
  }

  /// 群聊连续气泡是否保留头像占位（对齐气泡左缘）。
  /// 连续折叠已关闭，始终返回 false。
  static bool shouldReserveAvatarSpace({
    required bool isGroupMode,
    required bool collapseSenderChrome,
  }) {
    return isGroupMode && collapseSenderChrome;
  }

  /// 群聊默认展开的消息：列表中最后一条可展示、非系统消息。
  ///
  /// 若最后一条是己方消息，或没有符合条件的消息，返回 null（全部默认收起）。
  static String? defaultExpandedGroupMessageId(List<Message> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      if (!ChatHistoryContent.shouldDisplayInChat(message)) continue;
      if (message.isSystemMessage ||
          message.type == MessageType.permissionAudit) {
        continue;
      }
      final isMyMessage = message.from.type == 'user' &&
          message.from.id != SheService.sheId;
      return isMyMessage ? null : message.id;
    }
    return null;
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

/// 记住 [MessageUtils.orderForDisplay] 的结果。
///
/// 流式输出只替换消息对象，id / 时间戳 / replyTo 不变。顺序没变时直接返回
/// 原列表；曾经排过序时按保存的下标重取，保证气泡拿到的是替换后的对象。
class DisplayOrderMemo {
  String? _key;
  List<Message>? _source;
  List<int>? _perm;

  /// 最近一次参与比较的结构键（id、时间戳、回复关系、类型、在途流式 id）。
  String? get structuralKey => _key;

  List<Message> apply(
    List<Message> messages, {
    Set<String> streamingIds = const {},
  }) {
    final key = _structuralKey(messages, streamingIds);
    if (key == _key && identical(_source, messages)) {
      final perm = _perm;
      if (perm != null && perm.length == messages.length) {
        return [for (final i in perm) messages[i]];
      }
      if (perm == null) return messages;
    }
    final ordered = MessageUtils.orderForDisplay(
      messages,
      streamingIds: streamingIds,
    );
    _key = key;
    _source = messages;
    if (identical(ordered, messages)) {
      _perm = null;
      return messages;
    }
    final indexOf = <String, int>{
      for (var i = 0; i < messages.length; i++) messages[i].id: i,
    };
    final perm = <int>[];
    for (final message in ordered) {
      final index = indexOf[message.id];
      if (index == null) {
        _perm = null;
        return ordered;
      }
      perm.add(index);
    }
    _perm = perm;
    return ordered;
  }

  static String _structuralKey(
    List<Message> messages,
    Set<String> streamingIds,
  ) {
    final buffer = StringBuffer()..write(messages.length);
    for (final message in messages) {
      buffer
        ..write('\n')
        ..write(message.id)
        ..write('\t')
        ..write(message.timestampMs)
        ..write('\t')
        ..write(message.replyTo ?? '')
        ..write('\t')
        ..write(message.type.index);
    }
    if (streamingIds.isNotEmpty) {
      final ids = streamingIds.toList()..sort();
      buffer
        ..write('\n#')
        ..writeAll(ids, ',');
    }
    return buffer.toString();
  }
}
