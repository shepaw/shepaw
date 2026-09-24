import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/l10n_helpers.dart';
import '../../services/event/event_bus.dart';
import 'widgets/event_hints.dart';

/// 已注册事件类型浏览（只读），按命名空间分组 + 搜索。
///
/// `registry.all` 会运行期增长：首次 emit `agent.<id>.*` 会插一条，只有
/// `EventBus.resetRuntimeState` 回收。所以每次 build 都重新读，不做缓存。
class EventTypesTab extends StatefulWidget {
  const EventTypesTab({super.key});

  @override
  State<EventTypesTab> createState() => _EventTypesTabState();
}

class _EventTypesTabState extends State<EventTypesTab>
    // 保住搜索词与滚动位置。
    with AutomaticKeepAliveClientMixin {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<EventTypeDefinition> _filtered(AppLocalizations l10n) {
    final all = EventBus.instance.registry.all.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all
        .where(
          (t) =>
              t.id.toLowerCase().contains(q) ||
              t.description.toLowerCase().contains(q) ||
              localizeEventTypeLabel(l10n, t.id).toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context);
    final types = _filtered(l10n);

    final grouped = <String, List<EventTypeDefinition>>{};
    for (final t in types) {
      grouped.putIfAbsent(t.id.split('.').first, () => []).add(t);
    }
    final namespaces = grouped.keys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            key: const Key('event_types_search'),
            controller: _search,
            decoration: InputDecoration(
              hintText: l10n.eventMgmt_typesSearch,
              prefixIcon: const Icon(Icons.search, size: 18),
              border: const OutlineInputBorder(),
              isDense: true,
              suffixText: l10n.eventMgmt_typesCount(types.length),
              suffixStyle: const TextStyle(fontSize: 11),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: types.isEmpty
              ? EventEmptyHint(
                  text: l10n.eventMgmt_typesEmpty,
                  icon: Icons.category_outlined,
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    for (final ns in namespaces) ...[
                      _NamespaceHeader(
                        label: localizeEventFamilyLabel(l10n, ns) ?? ns,
                        namespace: ns,
                        count: grouped[ns]!.length,
                      ),
                      for (final type in grouped[ns]!)
                        _TypeTile(
                          definition: type,
                          localizedName: localizeEventTypeLabel(l10n, type.id),
                        ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _NamespaceHeader extends StatelessWidget {
  final String label;
  final String namespace;
  final int count;

  const _NamespaceHeader({
    required this.label,
    required this.namespace,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.grey.withValues(alpha: 0.06),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 6),
          Text(
            namespace,
            style: TextStyle(
              fontSize: 10.5,
              fontFamily: 'monospace',
              color: Colors.grey[600],
            ),
          ),
          const Spacer(),
          Text(
            '$count',
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}

class _TypeTile extends StatelessWidget {
  final EventTypeDefinition definition;
  final String localizedName;

  const _TypeTile({required this.definition, required this.localizedName});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final delivery = definition.defaultDelivery.localizedLabel(l10n);
    final scopeKeys = definition.requiredScopeKeys;
    final envelopeKeys = definition.requiredEnvelopeKeys;
    final none = l10n.eventMgmt_typesRequiredNone;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  localizedName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
              ),
              Text(
                '${l10n.eventMgmt_typesDefaultDelivery} · $delivery',
                style: TextStyle(fontSize: 10.5, color: Colors.grey[600]),
              ),
            ],
          ),
          Text(
            definition.id,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.4,
              fontFamily: 'monospace',
              color: Colors.grey[600],
            ),
          ),
          if (definition.description.isNotEmpty)
            Text(
              definition.description,
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          Text(
            '${l10n.eventMgmt_typesScopeKeys}: '
            '${scopeKeys.isEmpty ? none : scopeKeys.join(', ')}'
            '   '
            '${l10n.eventMgmt_typesEnvelopeKeys}: '
            '${envelopeKeys.isEmpty ? none : envelopeKeys.join(', ')}',
            style: TextStyle(fontSize: 10.5, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}
