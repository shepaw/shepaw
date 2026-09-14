import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/l10n_helpers.dart';
import '../../services/event/event_bus.dart';
import 'event_cli.dart';
import 'widgets/event_hints.dart';
import 'widgets/event_row.dart';

/// 订阅（增 / 删）+ 等待租约（查看 / 取消）。
///
/// 订阅的增删走 CLI（权限闸门与 `--persist` 落库都在命令内部）；租约取消没有
/// 对应的 CLI 子命令，直接调 [EventBus.cancelWaitLease]。
class EventListenTab extends StatefulWidget {
  final String agentId;

  const EventListenTab({super.key, required this.agentId});

  @override
  State<EventListenTab> createState() => _EventListenTabState();
}

class _EventListenTabState extends State<EventListenTab>
    // 数据全部派生自 EventBus，这里只是保住滚动位置。
    with AutomaticKeepAliveClientMixin {
  @override
  void initState() {
    super.initState();
    EventBus.instance.listenListenable.addListener(_onBusChanged);
  }

  @override
  void dispose() {
    EventBus.instance.listenListenable.removeListener(_onBusChanged);
    super.dispose();
  }

  void _onBusChanged() {
    if (mounted) setState(() {});
  }

  List<EventSubscription> get _subscriptions =>
      EventBus.instance.subscriptionsFor(widget.agentId);

  List<WaitLease> get _leases => EventBus.instance.activeWaitLeases
      .where((l) => l.agentId == widget.agentId)
      .toList();

  Future<void> _createSubscription() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _NewSubscriptionDialog(agentId: widget.agentId),
    );
    if (created == true && mounted) setState(() {});
  }

  Future<void> _unsubscribe(EventSubscription sub) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.eventMgmt_listenUnsubscribe),
        content: Text(
          '${l10n.eventMgmt_listenUnsubscribeConfirm}\n\n'
          '${sub.patterns.map((p) => p.typeGlob).join(', ')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            key: const Key('event_unsubscribe_confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.eventMgmt_listenUnsubscribe),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final result = await runEventsCli(
      subcommand: 'unsubscribe',
      agentId: widget.agentId,
      flags: {'subscription': sub.id},
    );
    if (!mounted) return;
    final error = result['error'];
    if (error != null) {
      _toast(l10n.eventMgmt_unsubscribeFailed('$error'));
      return;
    }
    setState(() {});
  }

  Future<void> _cancelLease(WaitLease lease) async {
    final l10n = AppLocalizations.of(context);
    // 先确认：取消会让等待方拿到取消异常，不是说取消就取消的本地操作。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.eventMgmt_listenCancelLease),
        content: Text(l10n.eventMgmt_listenCancelLeaseConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            key: const Key('event_lease_cancel_confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.eventMgmt_listenCancelLease),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _guardUnawaitedLease(lease);
    EventBus.instance.cancelWaitLease(lease.leaseId);
    setState(() {});
    _toast(l10n.eventMgmt_listenLeaseCancelled);
  }

  /// `WaitLease.cancel()` 走 `completer.completeError`。若此刻没有
  /// `waitOnLease` 在 await 这个 completer（管理页可以取消别人开的、或已经
  /// 没人等的租约），错误就会变成未捕获的异步异常。先挂一个空 listener：
  /// 真正的等待者照样收到异常，旁观者不会炸 Zone。
  void _guardUnawaitedLease(WaitLease lease) {
    unawaited(lease.completer.future.then<void>((_) {}, onError: (_, __) {}));
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
    final subs = _subscriptions;
    final leases = _leases;

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        _SectionHeader(
          title: l10n.eventMgmt_listenSubscriptions,
          count: subs.length,
          action: TextButton.icon(
            onPressed: _createSubscription,
            icon: const Icon(Icons.add, size: 16),
            label: Text(l10n.eventMgmt_listenCreate),
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
        if (subs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              l10n.eventMgmt_listenNoSubscriptions,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          )
        else
          for (final sub in subs) _buildSubscriptionRow(l10n, sub),
        const Divider(height: 24),
        _SectionHeader(
          title: l10n.eventMgmt_listenLeases,
          count: leases.length,
        ),
        if (leases.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              l10n.eventMgmt_listenNoLeases,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          )
        else
          for (final lease in leases) _buildLeaseRow(l10n, lease),
      ],
    );
  }

  Widget _buildSubscriptionRow(
    AppLocalizations l10n,
    EventSubscription sub,
  ) {
    return Column(
      key: Key('event_subscription_${sub.id}'),
      children: [
        for (final pattern in sub.patterns)
          EventRow(
            icon: Icons.sensors,
            title: localizeEventTypeLabel(l10n, pattern.typeGlob),
            rawLabel: pattern.typeGlob,
            delivery: sub.delivery.wireValue,
            meta: [
              sub.persistent
                  ? l10n.eventMgmt_listenPersistent
                  : l10n.eventMgmt_listenUntilRestart,
              if (pattern.scope.isNotEmpty)
                pattern.scope.entries
                    .map((e) => '${e.key}=${e.value}')
                    .join(' '),
              sub.id,
            ].where((s) => s.isNotEmpty).join(' · '),
            trailing: [
              IconButton(
                tooltip: l10n.eventMgmt_listenUnsubscribe,
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => _unsubscribe(sub),
              ),
            ],
          ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _buildLeaseRow(AppLocalizations l10n, WaitLease lease) {
    final correlation = lease.correlationId;
    return Column(
      key: Key('event_lease_${lease.leaseId}'),
      children: [
        for (final pattern in lease.typePatterns)
          EventRow(
            icon: Icons.hourglass_empty,
            iconColor: Colors.orange[700],
            title: localizeEventTypeLabel(l10n, pattern),
            rawLabel: pattern,
            meta: [
              l10n.eventMgmt_listenExpiresAt(
                formatEventClock(lease.expiresAt),
              ),
              if (correlation != null && correlation.isNotEmpty) correlation,
              'seq ${lease.seqAtOpen}',
            ].join(' · '),
            trailing: [
              TextButton(
                key: Key('event_lease_cancel_${lease.leaseId}'),
                onPressed: () => _cancelLease(lease),
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  l10n.eventMgmt_listenCancelLease,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        const Divider(height: 1),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final Widget? action;

  const _SectionHeader({
    required this.title,
    required this.count,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 2),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          const Spacer(),
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// 新建订阅表单。
///
/// 刻意用结构化字段而不是 `_CliDetailSheet` 的自由文本 flag 框 —— 后者正是
/// 本页要取代的东西。
class _NewSubscriptionDialog extends StatefulWidget {
  final String agentId;

  const _NewSubscriptionDialog({required this.agentId});

  @override
  State<_NewSubscriptionDialog> createState() => _NewSubscriptionDialogState();
}

class _NewSubscriptionDialogState extends State<_NewSubscriptionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _pattern = TextEditingController();
  final _channel = TextEditingController();
  final _owner = TextEditingController();
  final _peer = TextEditingController();

  EventDelivery _delivery = EventDelivery.pollOnly;
  bool _persist = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _pattern.dispose();
    _channel.dispose();
    _owner.dispose();
    _peer.dispose();
    super.dispose();
  }

  String _deliveryHint(AppLocalizations l10n) {
    switch (_delivery) {
      case EventDelivery.pollOnly:
        return l10n.eventMgmt_deliveryPollOnlyHint;
      case EventDelivery.passive:
        return l10n.eventMgmt_deliveryPassiveHint;
      case EventDelivery.active:
        return l10n.eventMgmt_deliveryActiveHint;
    }
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    if (_formKey.currentState?.validate() != true) return;

    setState(() {
      _submitting = true;
      _error = null;
    });

    final flags = <String, String>{
      'pattern': _pattern.text.trim(),
      'delivery': _delivery.wireValue,
      if (_persist) 'persist': '',
      if (_channel.text.trim().isNotEmpty) 'channel_id': _channel.text.trim(),
      if (_owner.text.trim().isNotEmpty) 'owner_id': _owner.text.trim(),
      if (_peer.text.trim().isNotEmpty) 'peer_id': _peer.text.trim(),
    };

    final result = await runEventsCli(
      subcommand: 'subscribe',
      agentId: widget.agentId,
      flags: flags,
    );
    if (!mounted) return;

    final error = result['error'];
    if (error != null) {
      setState(() {
        _submitting = false;
        _error = l10n.eventMgmt_subscribeFailed('$error');
      });
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.eventMgmt_listenCreate),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const Key('event_subscribe_pattern'),
                  controller: _pattern,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l10n.eventMgmt_pattern,
                    hintText: l10n.eventMgmt_patternHint,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? l10n.eventMgmt_patternRequired
                      : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<EventDelivery>(
                  key: const Key('event_subscribe_delivery'),
                  initialValue: _delivery,
                  decoration: InputDecoration(
                    labelText: l10n.eventMgmt_deliveryLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: EventDelivery.values
                      .map(
                        (d) => DropdownMenuItem(
                          value: d,
                          child: Text(d.localizedLabel(l10n)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(
                    () => _delivery = v ?? EventDelivery.pollOnly,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _deliveryHint(l10n),
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
                SwitchListTile(
                  key: const Key('event_subscribe_persist'),
                  value: _persist,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    l10n.eventMgmt_persist,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    l10n.eventMgmt_persistHint,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onChanged: (v) => setState(() => _persist = v),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.eventMgmt_scopeOptional,
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _channel,
                  decoration: InputDecoration(
                    labelText: l10n.eventMgmt_scopeChannel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _owner,
                  decoration: InputDecoration(
                    labelText: l10n.eventMgmt_scopeOwner,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _peer,
                  decoration: InputDecoration(
                    labelText: l10n.eventMgmt_scopePeer,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          key: const Key('event_subscribe_submit'),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.eventMgmt_listenCreate),
        ),
      ],
    );
  }
}
