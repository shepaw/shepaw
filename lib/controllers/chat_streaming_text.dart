import '../models/message.dart';

/// Pure helpers for in-flight streaming message text / metadata.
class ChatStreamingText {
  ChatStreamingText._();

  static const stoppedMarker = '[Stopped]';

  /// Append a visible stop marker, or return the marker alone when empty.
  static String withStoppedMarker(String content) {
    if (content.isNotEmpty) return '$content\n\n$stoppedMarker';
    return stoppedMarker;
  }

  /// Copy [message] with a new content string (preserves routing fields).
  ///
  /// [timestampMs] 显式覆盖原时间戳——复用上一回合的流式占位时需要把气泡
  /// 抬到当前最新消息之后，否则排序会把它顶到列表上方。
  static Message withUpdatedContent(
    Message message,
    String content, {
    int? timestampMs,
  }) {
    return Message(
      id: message.id,
      content: content,
      timestampMs: timestampMs ?? message.timestampMs,
      from: message.from,
      to: message.to,
      channelId: message.channelId,
      type: message.type,
      replyTo: message.replyTo,
      metadata: message.metadata,
    );
  }

  /// Copy [message] merging [patch] into metadata.
  static Message withMergedMetadata(
    Message message,
    Map<String, dynamic> patch,
  ) {
    final existing = Map<String, dynamic>.from(message.metadata ?? {});
    existing.addAll(patch);
    return Message(
      id: message.id,
      content: message.content,
      timestampMs: message.timestampMs,
      from: message.from,
      to: message.to,
      channelId: message.channelId,
      type: message.type,
      replyTo: message.replyTo,
      metadata: existing,
    );
  }

  /// Copy [message] with stopped content (preserves metadata / routing fields).
  static Message markMessageStopped(Message message, {String? contentOverride}) {
    return withUpdatedContent(
      message,
      withStoppedMarker(contentOverride ?? message.content),
    );
  }

  /// Build a transient streaming placeholder bubble.
  static Message placeholder({
    required String id,
    required MessageFrom from,
    MessageFrom? to,
    int? timestampMs,
    Map<String, dynamic>? metadata,
  }) {
    return Message(
      id: id,
      content: '',
      timestampMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch,
      from: from,
      to: to,
      type: MessageType.text,
      metadata: metadata,
    );
  }

  /// Find the newest in-flight streaming host bubble for [fromId].
  ///
  /// Used to self-heal when a mid-turn reload folded/dropped the `streaming_*`
  /// temp bubble: the accumulated content is then applied onto the flushed
  /// partial row (`status: streaming`) or a surviving temp instead of being
  /// silently discarded. `group: true` also matches `group_streaming_*` /
  /// `wf_streaming_*` temps used by group/workflow turns.
  static Message? findStreamingHost(
    List<Message> messages, {
    String? fromId,
    bool group = false,
  }) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (!m.from.isAgent) continue;
      if (fromId != null && fromId.isNotEmpty && m.from.id != fromId) continue;
      if (m.metadata?['status'] == 'streaming') return m;
      final id = m.id;
      final matches = group
          ? (id.startsWith('group_streaming_') || id.startsWith('wf_streaming_'))
          : id.startsWith('streaming_');
      if (matches) return m;
    }
    return null;
  }
}

/// Tracks the active DM streaming bubble id + accumulated content.
class ChatStreamingSession {
  String? messageId;
  String content = '';

  /// 流式回合的发送方 agent id。自愈查找（[repointAnchor]）用它限定
  /// 同发送者的气泡，避免 reload 折叠占位后 chunk 被静默丢弃。
  String? fromId;

  /// 会话开始时间戳（[begin] 设置、[clear] 清空）。用于区分「回合刚
  /// 开始、任务还没登记」与「僵尸会话」，以及判断 DB 中是否已出现本
  /// 回合的回复行（见 ChatMessageReconciler.dbHasTurnReply）。
  int? beganAtMs;

  /// 最后一次收到 chunk 的时间戳（[begin]/[append] 设置、[clear] 清空）。
  /// 新鲜度判定（[activeWithin]）以它为准：只要还在出字，回合就不能被
  /// 当成僵尸清掉——首 token 慢的长回合不应因为「距发送已超过 N 秒」
  /// 而丢失后续 chunk。
  int? lastActivityAtMs;

  /// 回合（或占位会话）结束时触发一次。控制器用它补做流式期间被推迟的
  /// DB reconcile（见 ChatController._dmReconcileAfterStreaming）。
  void Function()? onClear;

  bool get isActive => messageId != null;

  /// DM 全量刷新（reloadMessagesFromDB）的推迟判定。
  ///
  /// 流式会话存活时应推迟全量替换，避免顶掉流式占位气泡。
  /// [hasLiveTask] 可选：能区分「任务仍在跑」与「僵尸会话」的调用方传入
  /// `false` 可立即刷新自愈；省略时默认视为任务仍在（回合一开始任务
  /// 可能尚未登记，不能用「没有 ActiveTask」误判）。
  static bool shouldDeferReload({
    required bool streamingActive,
    bool hasLiveTask = true,
  }) =>
      streamingActive && hasLiveTask;

  void begin(String id, {String? fromId}) {
    messageId = id;
    content = '';
    this.fromId = fromId;
    final now = DateTime.now().millisecondsSinceEpoch;
    beganAtMs = now;
    lastActivityAtMs = now;
  }

  void append(String chunk) {
    content += chunk;
    lastActivityAtMs = DateTime.now().millisecondsSinceEpoch;
  }

  void clear() {
    final wasActive = messageId != null;
    messageId = null;
    content = '';
    fromId = null;
    beganAtMs = null;
    lastActivityAtMs = null;
    if (wasActive) onClear?.call();
  }

  /// 会话是否在 [window] 内刚刚开始（任务尚未登记也按活跃处理）。
  bool beganWithin(Duration window) {
    final t = beganAtMs;
    return t != null &&
        DateTime.now().millisecondsSinceEpoch - t <= window.inMilliseconds;
  }

  /// 会话在 [window] 内是否仍有活动：最后一个 chunk 落在窗口内，或回合
  /// 才开始（还没有 chunk，此时以 [beganAtMs] 为准）。
  ///
  /// 与 [beganWithin] 的区别：回合持续出字时永远新鲜，不会因为「发送后
  /// 已过 N 秒」被误判为僵尸。
  bool activeWithin(Duration window) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = lastActivityAtMs ?? beganAtMs;
    return last != null && now - last <= window.inMilliseconds;
  }

  /// 会话是否已沦为「僵尸」：锚点气泡已不在 [messages] 中（reload 折叠/
  /// 替换占位后无宿主可回指，[repointAnchor] 也失败）且没有存活任务。
  ///
  /// 僵尸会话的 streaming.clear() 永远等不到回合终态（任务已不在），
  /// streaming.isActive 永久为 true → 后续 reloadMessagesFromDB 全部被
  /// defer（UI 卡「等待回复」，重进才恢复）。调用方应在加载完成后检查
  /// 并强制清理（活回合由 reattach 重新 begin，不受影响）。
  bool isOrphan({
    required List<Message> messages,
    required bool hasLiveTask,
  }) {
    if (!isActive) return false;
    if (hasLiveTask) return false;
    if (messages.any((m) => m.id == messageId)) return false;
    return true;
  }

  /// 若当前锚点气泡已不在 [messages] 中（回合中途 reload 折叠/丢弃了
  /// 占位），把锚点改指到同发送者的在途宿主（flush 部分行或残余占位）。
  /// 命中后返回 true。用于应用 chunk 前自愈，以及 reload 后立即恢复
  /// streaming 标记。
  bool repointAnchor(List<Message> messages,
      {Map<String, Message>? messageIdMap}) {
    final id = messageId;
    if (id == null) return false;
    // 快路径：每个 chunk 都会调一次，map 命中即可判定锚点存活，O(1)。
    // map 未命中时仍退化为列表扫描，保证与原来的判定一致。
    final map = messageIdMap;
    if (map != null && map.containsKey(id)) return false;
    if (messages.any((m) => m.id == id)) return false;
    final host = ChatStreamingText.findStreamingHost(messages, fromId: fromId);
    if (host == null) return false;
    messageId = host.id;
    return true;
  }

  /// Apply accumulated [content] onto the matching message in [messages].
  /// Returns the updated message, or null if not found.
  ///
  /// 找不到锚点时先尝试 [repointAnchor] 自愈——否则 reload 折叠占位后
  /// 本回合剩余 chunk 会被静默丢弃（UI 一直卡在等待状态）。
  Message? applyContentTo(
    List<Message> messages,
    Map<String, Message> messageIdMap,
  ) {
    final id = messageId;
    if (id == null) return null;
    repointAnchor(messages, messageIdMap: messageIdMap);
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return null;
    final updated = ChatStreamingText.withUpdatedContent(messages[idx], content);
    messages[idx] = updated;
    messageIdMap[updated.id] = updated;
    if (messageId != id) {
      // 锚点被改指：旧的占位 id 已被 reload 顶掉，清掉残留映射。
      messageIdMap.remove(id);
    }
    return updated;
  }

  /// Merge metadata onto the active streaming message.
  ///
  /// thinking/进度帧也算活动，同样刷新 [lastActivityAtMs]：纯思考阶段
  /// 可能长时间没有正文 chunk，不应被新鲜度判定当成僵尸。
  Message? applyMetadataTo(
    List<Message> messages,
    Map<String, Message> messageIdMap,
    Map<String, dynamic> patch,
  ) {
    final id = messageId;
    if (id == null) return null;
    lastActivityAtMs = DateTime.now().millisecondsSinceEpoch;
    repointAnchor(messages, messageIdMap: messageIdMap);
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return null;
    final updated = ChatStreamingText.withMergedMetadata(messages[idx], patch);
    messages[idx] = updated;
    messageIdMap[updated.id] = updated;
    if (messageId != id) {
      messageIdMap.remove(id);
    }
    return updated;
  }
}
