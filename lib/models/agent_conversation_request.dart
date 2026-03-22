class AgentConversationRequest {
  final String id;
  final String requesterId;
  final String targetId;
  final String message;
  final Map<String, dynamic>? context;
  final String status; // pending, approved, rejected
  final int requestedAt;
  final int? approvedAt;
  final String? approvedBy;

  // 用于显示的附加信息
  String? requesterName;
  String? requesterAvatar;
  String? targetName;
  String? targetAvatar;

  AgentConversationRequest({
    required this.id,
    required this.requesterId,
    required this.targetId,
    required this.message,
    this.context,
    required this.status,
    required this.requestedAt,
    this.approvedAt,
    this.approvedBy,
    this.requesterName,
    this.requesterAvatar,
    this.targetName,
    this.targetAvatar,
  });

  factory AgentConversationRequest.fromJson(Map<String, dynamic> json) {
    return AgentConversationRequest(
      id: json['id'] as String,
      requesterId: json['requester_id'] as String,
      targetId: json['target_id'] as String,
      message: json['message'] as String,
      context: json['context'] as Map<String, dynamic>?,
      status: json['status'] as String,
      requestedAt: json['requested_at'] as int,
      approvedAt: json['approved_at'] as int?,
      approvedBy: json['approved_by'] as String?,
      requesterName: json['requester_name'] as String?,
      requesterAvatar: json['requester_avatar'] as String?,
      targetName: json['target_name'] as String?,
      targetAvatar: json['target_avatar'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'requester_id': requesterId,
      'target_id': targetId,
      'message': message,
      'context': context,
      'status': status,
      'requested_at': requestedAt,
      'approved_at': approvedAt,
      'approved_by': approvedBy,
    };
  }

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';

  DateTime get requestedDateTime =>
      DateTime.fromMillisecondsSinceEpoch(requestedAt);

  String get timeAgo {
    final now = DateTime.now();
    final diff = now.difference(requestedDateTime);

    if (diff.inMinutes < 1) {
      return '刚刚';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes} 分钟前';
    } else if (diff.inHours < 24) {
      return '${diff.inHours} 小时前';
    } else {
      return '${diff.inDays} 天前';
    }
  }
}
