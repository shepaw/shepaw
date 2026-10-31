/// Agent 私聊会话按来源折叠（折叠方案 §2 / §3）。
library;

enum SessionFolderKind {
  group('group'),
  delegated('delegated'),
  flow('flow'),
  ide('ide'),
  terminal('terminal');

  const SessionFolderKind(this.wire);

  final String wire;

  static SessionFolderKind? parse(Object? raw) {
    for (final kind in SessionFolderKind.values) {
      if (kind.wire == raw) return kind;
    }
    return null;
  }
}

/// 一个折叠组的摘要行："群聊 · 6"。
class SessionFolderSummary {
  const SessionFolderSummary({
    required this.kind,
    required this.count,
    required this.updatedAt,
    required this.latestTitle,
  });

  final SessionFolderKind kind;
  final int count;
  final int updatedAt;
  final String latestTitle;

  static SessionFolderSummary? fromJson(Map<String, dynamic> json) {
    final kind = SessionFolderKind.parse(json['kind']);
    if (kind == null) return null;
    return SessionFolderSummary(
      kind: kind,
      count: (json['count'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      latestTitle: (json['latest_title'] as String?) ?? '',
    );
  }
}

/// 折叠组里的一项。只读，可以分叉到私聊。
class FoldedSession {
  const FoldedSession({
    required this.sessionId,
    required this.title,
    required this.updatedAt,
    required this.source,
    required this.originKind,
    this.groupId = '',
    this.groupSessionId = '',
    this.runId = '',
    this.nodeKey = '',
    this.fromAgent = '',
    this.hostName = '',
    this.messageCount,
  });

  final String sessionId;
  final String title;
  final int updatedAt;
  final String source;
  final String originKind;
  final String groupId;
  final String groupSessionId;
  final String runId;
  final String nodeKey;
  final String fromAgent;
  final String hostName;
  final int? messageCount;

  bool get isFlow => originKind == 'flow';
  bool get isGroup => originKind == 'group';

  factory FoldedSession.fromJson(Map<String, dynamic> json) {
    final origin = json['origin'] is Map
        ? Map<String, dynamic>.from(json['origin'] as Map)
        : const <String, dynamic>{};
    String text(Object? v) => v is String ? v : '';
    return FoldedSession(
      sessionId: text(json['session_id']),
      title: text(json['title']),
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      source: text(json['source']),
      originKind: text(origin['kind']),
      groupId: text(origin['group_id']),
      groupSessionId: text(origin['session_id']),
      runId: text(origin['run_id']),
      nodeKey: text(origin['node_key']),
      fromAgent: text(origin['from_agent']),
      hostName: text(origin['host_name']),
      messageCount: (json['message_count'] as num?)?.toInt(),
    );
  }
}

/// 折叠组明细的一页。`cursor` 为空表示没有下一页。
class FoldedPage {
  const FoldedPage({required this.items, this.cursor});

  final List<FoldedSession> items;
  final String? cursor;

  static FoldedPage? fromResponse(Map<String, dynamic> response) {
    final raw = response['sessions'];
    if (raw is! List) return null;
    final cursor = response['cursor'];
    return FoldedPage(
      items: [
        for (final item in raw)
          if (item is Map)
            FoldedSession.fromJson(Map<String, dynamic>.from(item)),
      ],
      cursor: cursor is String && cursor.isNotEmpty ? cursor : null,
    );
  }
}

/// 折叠视图的摘要：平铺区只有私聊（原样交给现有名单解码），加上各组行。
class FoldedSummary {
  const FoldedSummary({required this.folders});

  final List<SessionFolderSummary> folders;

  static FoldedSummary? fromResponse(Map<String, dynamic> response) {
    final raw = response['folders'];
    if (raw is! List) return null;
    final folders = <SessionFolderSummary>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final folder =
          SessionFolderSummary.fromJson(Map<String, dynamic>.from(item));
      if (folder != null) folders.add(folder);
    }
    return FoldedSummary(folders: folders);
  }
}

/// 群聊视角的一条消息：这个 Agent 在群会话里的发言（折叠方案 §3.3）。
class GroupViewMessage {
  const GroupViewMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  final String id;
  final String role;
  final String content;
  final String createdAt;
}

/// `agent_group_view_resp` 的一页。游标顺着往后翻；`reset` 为真表示主机那边的
/// 前缀变了，要丢掉已有的从头来。
class GroupViewPage {
  const GroupViewPage({
    required this.messages,
    required this.cursor,
    required this.hasMore,
    required this.total,
    this.reset = false,
  });

  final List<GroupViewMessage> messages;
  final String cursor;
  final bool hasMore;
  final int total;
  final bool reset;

  static GroupViewPage? fromResponse(Map<String, dynamic> response) {
    if (response['error'] != null) return null;
    final raw = response['messages'];
    if (raw is! List) return null;
    String text(Object? v) => v is String ? v : '';
    return GroupViewPage(
      messages: [
        for (final item in raw)
          if (item is Map)
            GroupViewMessage(
              id: text(item['message_id']),
              role: text(item['role']),
              content: text(item['content']),
              createdAt: text(item['created_at']),
            ),
      ],
      cursor: text(response['cursor']),
      hasMore: response['has_more'] == true,
      total: (response['total'] as num?)?.toInt() ?? raw.length,
      reset: response['reset'] == true,
    );
  }
}

/// 会话的来源（`origin.kind`）。私聊不折叠，其余各归一组。
class SessionOrigin {
  const SessionOrigin({
    required this.kind,
    this.groupId = '',
    this.groupSessionId = '',
    this.runId = '',
    this.nodeKey = '',
    this.fromAgent = '',
    this.hostName = '',
  });

  final String kind;
  final String groupId;
  final String groupSessionId;
  final String runId;
  final String nodeKey;
  final String fromAgent;
  final String hostName;

  bool get isPrivate => kind.isEmpty || kind == 'private';

  factory SessionOrigin.private() => const SessionOrigin(kind: 'private');

  factory SessionOrigin.fromJson(Map<String, dynamic> json) {
    String text(Object? v) => v is String ? v : '';
    return SessionOrigin(
      kind: text(json['kind']).isEmpty ? 'private' : text(json['kind']),
      groupId: text(json['group_id']),
      groupSessionId: text(json['session_id']),
      runId: text(json['run_id']),
      nodeKey: text(json['node_key']),
      fromAgent: text(json['from_agent']),
      hostName: text(json['host_name']),
    );
  }
}

/// 会话搜索的一条结果（折叠方案 §2.3）。`origin` 就是来源角标：私聊可以直接
/// 接着聊，折叠组里的会话只读。
class SessionSearchHit {
  const SessionSearchHit({
    required this.agentId,
    required this.sessionId,
    required this.title,
    required this.source,
    required this.origin,
    required this.updatedAt,
    required this.readOnly,
    this.snippet,
  });

  final String agentId;
  final String sessionId;
  final String title;
  final String source;

  /// 来源角标（`origin.kind`：`private` / `group` / `flow` / `delegated` /
  /// `ide` / `terminal`）。
  final SessionOrigin origin;
  final int updatedAt;
  final bool readOnly;

  /// 正文里命中位置附近的一小段；标题命中的没有。
  final String? snippet;

  bool get isPrivate => origin.isPrivate;

  factory SessionSearchHit.fromJson(Map<String, dynamic> json) {
    final rawOrigin = json['origin'];
    return SessionSearchHit(
      agentId: (json['agent_id'] as String?) ?? '',
      sessionId: (json['session_id'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      source: (json['source'] as String?) ?? '',
      origin: rawOrigin is Map
          ? SessionOrigin.fromJson(Map<String, dynamic>.from(rawOrigin))
          : SessionOrigin.private(),
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      readOnly: json['read_only'] == true,
      snippet: json['snippet'] as String?,
    );
  }
}
