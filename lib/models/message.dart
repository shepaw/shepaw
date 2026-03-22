/// 消息发送者
class MessageFrom {
  final String id;
  final String type;
  final String name;

  MessageFrom({
    required this.id,
    required this.type,
    required this.name,
  });

  bool get isAgent => type == 'agent';
  bool get isUser => type == 'user';
  bool get isSystem => id == 'system';

  factory MessageFrom.fromJson(Map<String, dynamic> json) {
    return MessageFrom(
      id: json['id'] ?? '',
      type: json['type'] ?? 'user',
      name: json['name'] ?? '',
    );
  }
}

/// 消息类型
enum MessageType {
  text,
  image,
  file,
  audio,
  system,
  permissionAudit,
}

/// 消息
class Message {
  final String id;
  final MessageFrom from;
  final MessageFrom? to;
  final String? channelId;
  final MessageType type;
  final String content;
  final int timestampMs;
  final String? replyTo;
  final Map<String, dynamic>? metadata;

  Message({
    required this.id,
    required this.from,
    this.to,
    this.channelId,
    required this.type,
    required this.content,
    required this.timestampMs,
    this.replyTo,
    this.metadata,
  });

  /// Alternative constructor with senderId/senderName
  factory Message.simple({
    required String id,
    required String channelId,
    required String senderId,
    required String senderName,
    String senderType = 'user',
    required String content,
    required DateTime timestamp,
    required MessageType type,
    String? replyToId,
    Map<String, dynamic>? metadata,
  }) {
    return Message(
      id: id,
      channelId: channelId,
      from: MessageFrom(
        id: senderId,
        type: senderType,
        name: senderName,
      ),
      type: type,
      content: content,
      timestampMs: timestamp.millisecondsSinceEpoch,
      replyTo: replyToId,
      metadata: metadata,
    );
  }

  bool get isSystemMessage => from.isSystem;
  bool get isSentByMe => false; // 需要根据当前用户判断

  // For backward compatibility
  String get senderId => from.id;
  String get senderName => from.name;
  DateTime get timestamp => DateTime.fromMillisecondsSinceEpoch(timestampMs);

  DateTime get dateTime => DateTime.fromMillisecondsSinceEpoch(timestampMs);

  String get timeString {
    final dt = dateTime;
    final now = DateTime.now();
    
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } else {
      return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    MessageType msgType;
    switch (json['type']) {
      case 'text':
        msgType = MessageType.text;
        break;
      case 'image':
        msgType = MessageType.image;
        break;
      case 'file':
        msgType = MessageType.file;
        break;
      case 'audio':
        msgType = MessageType.audio;
        break;
      case 'system':
        msgType = MessageType.system;
        break;
      case 'permission_audit':
        msgType = MessageType.permissionAudit;
        break;
      default:
        msgType = MessageType.text;
    }

    return Message(
      id: json['id'] ?? '',
      from: MessageFrom.fromJson(json['from'] ?? {}),
      to: json['to'] != null ? MessageFrom.fromJson(json['to']) : null,
      channelId: json['channel_id'],
      type: msgType,
      content: json['content'] ?? '',
      timestampMs: json['timestamp'] ?? 0,
      replyTo: json['metadata']?['reply_to'],
      metadata: json['metadata'] != null ? Map<String, dynamic>.from(json['metadata']) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'from': {
        'id': from.id,
        'type': from.type,
        'name': from.name,
      },
      'to': to != null ? {
        'id': to!.id,
        'type': to!.type,
      } : null,
      'channel_id': channelId,
      'type': type.toString().split('.').last,
      'content': content,
      'timestamp': timestampMs,
      'metadata': metadata,
    };
  }
}
