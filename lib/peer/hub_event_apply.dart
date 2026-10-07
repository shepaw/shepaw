/// 主机事件日志在客户端上的纯规则：游标、缺口、重置、消息去重。
library;

class HubEvent {
  const HubEvent({
    required this.seq,
    required this.kind,
    required this.channelId,
    required this.agentId,
    required this.origin,
    required this.data,
  });

  final int seq;
  final String kind;
  final String channelId;
  final String agentId;
  final String origin;
  final Map<String, dynamic> data;

  static HubEvent? parse(Object? raw) {
    if (raw is! Map) return null;
    final seq = raw['seq'];
    final kind = raw['kind'];
    if (seq is! int || kind is! String || kind.isEmpty) return null;
    final data = raw['data'];
    return HubEvent(
      seq: seq,
      kind: kind,
      channelId: raw['channel_id'] as String? ?? '',
      agentId: raw['agent_id'] as String? ?? '',
      origin: raw['origin'] as String? ?? '',
      data: data is Map ? Map<String, dynamic>.from(data) : const {},
    );
  }
}

class HubSyncPage {
  const HubSyncPage({
    required this.events,
    required this.headSeq,
    required this.reset,
  });

  final List<HubEvent> events;
  final int headSeq;
  final bool reset;

  static HubSyncPage? parse(Map<String, dynamic> raw) {
    final head = raw['head_seq'];
    if (head is! int) return null;
    final events = <HubEvent>[];
    final listed = raw['events'];
    if (listed is List) {
      for (final item in listed) {
        final event = HubEvent.parse(item);
        if (event != null) events.add(event);
      }
    }
    return HubSyncPage(
      events: events,
      headSeq: head,
      reset: raw['reset'] == true,
    );
  }
}

/// 实时事件相对本地游标怎么处理。
enum HubCursorStep { apply, duplicate, gap }

HubCursorStep cursorStep(int lastSeq, int eventSeq) {
  if (eventSeq <= lastSeq) return HubCursorStep.duplicate;
  if (lastSeq != 0 && eventSeq != lastSeq + 1) return HubCursorStep.gap;
  return HubCursorStep.apply;
}

/// 一页同步之后的游标。重置时以这页最后一条为准，中间缺号不再补。
int cursorAfterPage(int lastSeq, HubSyncPage page) {
  if (page.events.isEmpty) return page.reset ? 0 : lastSeq;
  if (page.reset) return page.events.last.seq;
  var cursor = lastSeq;
  for (final event in page.events) {
    if (cursorStep(cursor, event.seq) == HubCursorStep.apply) {
      cursor = event.seq;
    }
  }
  return cursor;
}

bool syncCaughtUp(int cursor, int headSeq) => cursor >= headSeq;

/// 同一条消息 id 已经在本地时，不再插第二次。
bool shouldInsertMessage(bool exists) => !exists;

String liveTurnPlaceholderId(String turnId) => 'hub-live-$turnId';
