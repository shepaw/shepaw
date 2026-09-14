import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/l10n_helpers.dart';
import '../../services/event/event_bus.dart';
import 'widgets/event_hints.dart';
import 'widgets/event_payload_view.dart';
import 'widgets/event_row.dart';

/// 全局事件日志实时流 —— CLI 没有这个视图，但排查「为什么 agent 没收事件」
/// 时最有用：能看到事件确实发出去了、发到了哪个 scope、有没有被去重。
///
/// 数据源是 `busStore.log`（上限 1000 条、静默驱逐），随 [EventBus.emitListenable]
/// 实时刷新。
class EventRecentTab extends StatefulWidget {
  /// 最多渲染多少条（按 seq 倒序取最新的）。
  static const maxRows = 100;

  const EventRecentTab({super.key});

  @override
  State<EventRecentTab> createState() => _EventRecentTabState();
}

class _EventRecentTabState extends State<EventRecentTab> {
  @override
  void initState() {
    super.initState();
    EventBus.instance.emitListenable.addListener(_onBusChanged);
  }

  @override
  void dispose() {
    EventBus.instance.emitListenable.removeListener(_onBusChanged);
    super.dispose();
  }

  void _onBusChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final log = EventBus.instance.busStore.log;
    final recent = log.reversed.take(EventRecentTab.maxRows).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EventMemoryOnlyBanner(text: l10n.eventMgmt_memoryOnly),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Text(
                l10n.eventMgmt_recentCount(recent.length),
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
        Expanded(
          child: recent.isEmpty
              ? EventEmptyHint(
                  text: l10n.eventMgmt_recentEmpty,
                  icon: Icons.bolt_outlined,
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 32),
                  itemCount: recent.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final event = recent[index];
                    final scope = event.scope.toJson();
                    return EventRow(
                      key: Key('event_recent_${event.id}'),
                      icon: Icons.bolt,
                      title: localizeEventTypeLabel(l10n, event.type),
                      rawLabel: event.type,
                      meta: [
                        'seq ${event.seq}',
                        '${l10n.eventMgmt_recentSource}: ${event.source}',
                        formatEventClock(event.at),
                      ].join(' · '),
                      expanded: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (scope.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                scope.entries
                                    .map((e) => '${e.key}=${e.value}')
                                    .join('  '),
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontFamily: 'monospace',
                                  color: Colors.grey[600],
                                ),
                              ),
                            ),
                          EventPayloadView(payload: event.payload),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
