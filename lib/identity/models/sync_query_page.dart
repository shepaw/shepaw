import 'sync_event.dart';

/// sync_query 单页结果（含是否还有更多事件）。
class SyncQueryPage {
  final List<SyncEvent> events;
  final bool hasMore;

  const SyncQueryPage({
    required this.events,
    this.hasMore = false,
  });

  static const empty = SyncQueryPage(events: []);
}
