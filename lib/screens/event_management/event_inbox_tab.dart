import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/l10n_helpers.dart';
import '../../services/event/event_bus.dart';
import '../../services/event/event_inbox_store.dart';
import 'event_cli.dart';
import 'widgets/event_hints.dart';
import 'widgets/event_payload_view.dart';
import 'widgets/event_row.dart';

/// 收件箱：某个 agent 已投递的事件 + ack。
///
/// 分页没有总数：`EventInboxStore.inboxFor` 最后才 `take(limit)`，`count` 是
/// 截断后的数。下一页用最后一条的 `seq` 当 cursor，与 `inbox_command.dart` 一致。
class EventInboxTab extends StatefulWidget {
  final String agentId;

  static const pageSize = 20;

  const EventInboxTab({super.key, required this.agentId});

  @override
  State<EventInboxTab> createState() => _EventInboxTabState();
}

class _EventInboxTabState extends State<EventInboxTab>
    // 保住已翻的分页、滚动位置与「仅未读」开关。
    with AutomaticKeepAliveClientMixin {
  final List<InboxEntry> _entries = [];
  bool _unreadOnly = false;
  bool _loading = true;
  bool _hasMore = false;

  /// 用户翻过页：新事件到达时不打断浏览，只给一个手动刷新提示。
  bool _paged = false;
  bool _pendingNew = false;

  String? _busyEventId;

  @override
  void initState() {
    super.initState();
    _reload();
    EventBus.instance.emitListenable.addListener(_onBusChanged);
  }

  @override
  void didUpdateWidget(EventInboxTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agentId != widget.agentId) _reload();
  }

  @override
  void dispose() {
    EventBus.instance.emitListenable.removeListener(_onBusChanged);
    super.dispose();
  }

  void _onBusChanged() {
    if (!mounted) return;
    if (_paged) {
      setState(() => _pendingNew = true);
    } else {
      _reload();
    }
  }

  void _reload() {
    final entries = EventBus.instance.inboxFor(
      widget.agentId,
      limit: EventInboxTab.pageSize,
      unreadOnly: _unreadOnly,
    );
    if (!mounted) return;
    setState(() {
      _entries
        ..clear()
        ..addAll(entries);
      _hasMore = entries.length == EventInboxTab.pageSize;
      _paged = false;
      _pendingNew = false;
      _loading = false;
    });
  }

  void _loadMore() {
    if (_entries.isEmpty) return;
    final entries = EventBus.instance.inboxFor(
      widget.agentId,
      cursor: _entries.last.event.seq,
      limit: EventInboxTab.pageSize,
      unreadOnly: _unreadOnly,
    );
    setState(() {
      _entries.addAll(entries);
      _hasMore = entries.length == EventInboxTab.pageSize;
      _paged = true;
    });
  }

  Future<void> _ack(InboxEntry entry) async {
    setState(() => _busyEventId = entry.event.id);
    final result = await runEventsCli(
      subcommand: 'ack',
      agentId: widget.agentId,
      flags: {'id': entry.event.id},
    );
    if (!mounted) return;
    setState(() => _busyEventId = null);

    final error = result['error'];
    if (error != null) {
      _toast(AppLocalizations.of(context).eventMgmt_inboxAckFailed('$error'));
      return;
    }
    // CLI 只写 store 不 notify。就地改这一行而不是整表 reload：保住已翻的
    // 分页和滚动位置。store 里的真实写入由 CLI 完成。
    setState(() {
      entry.ackedAt = DateTime.now();
      if (_unreadOnly) _entries.remove(entry);
    });
    final count = result['acked_count'];
    if (count is int) {
      _toast(AppLocalizations.of(context).eventMgmt_inboxAckedCount(count));
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EventMemoryOnlyBanner(text: l10n.eventMgmt_memoryOnly),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: CheckboxListTile(
                  key: const Key('event_inbox_unread_only'),
                  value: _unreadOnly,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    l10n.eventMgmt_inboxUnreadOnly,
                    style: const TextStyle(fontSize: 13),
                  ),
                  onChanged: (v) {
                    setState(() {
                      _unreadOnly = v ?? false;
                      _loading = true;
                    });
                    _reload();
                  },
                ),
              ),
              Text(
                l10n.eventMgmt_inboxCount(_entries.length),
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
              IconButton(
                tooltip: l10n.common_refresh,
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: _reload,
              ),
            ],
          ),
        ),
        if (_pendingNew)
          Material(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
            child: InkWell(
              onTap: _reload,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.arrow_upward, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      l10n.common_refresh,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(child: _buildList(l10n)),
      ],
    );
  }

  Widget _buildList(AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_entries.isEmpty) {
      return EventEmptyHint(
        text: _unreadOnly && _hasEventsAtAll()
            ? l10n.eventMgmt_inboxNoUnread
            : l10n.eventMgmt_inboxEmpty,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: _entries.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index >= _entries.length) {
          return Center(
            child: TextButton(
              onPressed: _loadMore,
              child: Text(l10n.eventMgmt_inboxLoadMore),
            ),
          );
        }
        return _buildEntry(l10n, _entries[index]);
      },
    );
  }

  /// 「仅未读」下收件箱非空但过滤后为空 → 说明都确认过了。
  bool _hasEventsAtAll() =>
      EventBus.instance.inboxFor(widget.agentId, limit: 1).isNotEmpty;

  Widget _buildEntry(AppLocalizations l10n, InboxEntry entry) {
    final event = entry.event;
    final acked = entry.ackedAt != null;
    final busy = _busyEventId == event.id;
    final correlation = event.correlationId;

    return EventRow(
      icon: acked ? Icons.mark_email_read_outlined : Icons.inbox_outlined,
      iconColor: acked ? Colors.grey : null,
      title: localizeEventTypeLabel(l10n, event.type),
      rawLabel: event.type,
      delivery: entry.delivery,
      meta: [
        'seq ${event.seq}',
        entry.deliveredVia,
        if (correlation != null && correlation.isNotEmpty) correlation,
        formatEventClock(event.at),
      ].join(' · '),
      expanded: EventPayloadView(payload: event.payload),
      trailing: [
        if (acked)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 2),
            child: Text(
              l10n.eventMgmt_inboxAcked,
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          )
        else if (busy)
          const Padding(
            padding: EdgeInsets.only(left: 8, top: 4),
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else
          TextButton(
            key: Key('event_inbox_ack_${event.id}'),
            onPressed: () => _ack(entry),
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              l10n.eventMgmt_inboxAck,
              style: const TextStyle(fontSize: 12),
            ),
          ),
      ],
    );
  }
}

