/// 配对设备间的消息类型
enum PeerMessageType {
  text,
  file,
  system;

  String toJson() => name;

  static PeerMessageType fromJson(String value) {
    return PeerMessageType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => PeerMessageType.text,
    );
  }
}

/// 消息投递状态
enum PeerMessageDelivery {
  pending,
  sent,
  delivered,
  read,
  failed;

  String toJson() => name;

  static PeerMessageDelivery fromJson(String value) {
    return PeerMessageDelivery.values.firstWhere(
      (e) => e.name == value,
      orElse: () => PeerMessageDelivery.pending,
    );
  }
}

/// 配对设备间的消息
class PeerMessage {
  /// 消息唯一 ID
  final String id;

  /// 所属配对关系 ID
  final String peerId;

  /// 发送方设备 ID（自己或对方的 deviceId）
  final String senderId;

  /// 消息类型
  final PeerMessageType type;

  /// 消息内容
  final String content;

  /// 消息时间（毫秒时间戳）
  final int timestamp;

  /// 投递状态
  final PeerMessageDelivery delivery;

  PeerMessage({
    required this.id,
    required this.peerId,
    required this.senderId,
    required this.type,
    required this.content,
    required this.timestamp,
    this.delivery = PeerMessageDelivery.pending,
  });

  /// 从 JSON（数据库行）创建
  factory PeerMessage.fromJson(Map<String, dynamic> json) {
    return PeerMessage(
      id: json['id'] as String,
      peerId: json['peer_id'] as String,
      senderId: json['sender_id'] as String,
      type: PeerMessageType.fromJson(json['type'] as String),
      content: json['content'] as String,
      timestamp: json['timestamp'] as int,
      delivery: PeerMessageDelivery.fromJson(json['delivery'] as String? ?? 'pending'),
    );
  }

  /// 转换为 JSON（用于数据库存储）
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'peer_id': peerId,
      'sender_id': senderId,
      'type': type.toJson(),
      'content': content,
      'timestamp': timestamp,
      'delivery': delivery.toJson(),
    };
  }

  /// 转换为线路传输格式（不含 delivery 状态）
  Map<String, dynamic> toWireJson() {
    return {
      'id': id,
      'sender_id': senderId,
      'type': type.toJson(),
      'content': content,
      'timestamp': timestamp,
    };
  }

  /// 从线路传输格式创建
  factory PeerMessage.fromWireJson(Map<String, dynamic> json, String peerId) {
    return PeerMessage(
      id: json['id'] as String,
      peerId: peerId,
      senderId: json['sender_id'] as String,
      type: PeerMessageType.fromJson(json['type'] as String? ?? 'text'),
      content: json['content'] as String,
      timestamp: json['timestamp'] as int,
      delivery: PeerMessageDelivery.delivered,
    );
  }

  /// 复制并修改部分字段
  PeerMessage copyWith({
    String? id,
    String? peerId,
    String? senderId,
    PeerMessageType? type,
    String? content,
    int? timestamp,
    PeerMessageDelivery? delivery,
  }) {
    return PeerMessage(
      id: id ?? this.id,
      peerId: peerId ?? this.peerId,
      senderId: senderId ?? this.senderId,
      type: type ?? this.type,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      delivery: delivery ?? this.delivery,
    );
  }
}
