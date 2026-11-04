import 'dart:async';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_models.dart';
import '../../peer/services/hub_flow.dart';

/// 「最近运行」栏（M8'）。
///
/// 数据来自主机的 `flow_run_list_req` —— 元信息随运行快照落盘，所以主机重启、
/// 运行结束之后仍然列得出来。不在这台设备上开过的运行也能看到。
class FlowRunsPane extends StatefulWidget {
  const FlowRunsPane({
    super.key,
    required this.client,
    required this.peerId,
    this.scope = '',
    this.name = '',
    this.onOpenRun,
  });

  final HubFlow client;
  final String peerId;

  /// 为空表示不过滤。
  final String scope;
  final String name;

  final void Function(String runId, String title)? onOpenRun;

  @override
  State<FlowRunsPane> createState() => _FlowRunsPaneState();
}

class _FlowRunsPaneState extends State<FlowRunsPane> {
  List<FlowRunSummary>? _runs;
  bool _loading = true;
  StreamSubscription<FlowEvent>? _sub;

  @override
  void initState() {
    super.initState();
    // 运行状态变了要刷新列表，否则得手动点刷新或切 tab。
    _sub = widget.client
        .runEvents(widget.peerId)
        .listen((_) => unawaited(_load()));
    unawaited(_load());
  }

  @override
  void didUpdateWidget(FlowRunsPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peerId != widget.peerId ||
        oldWidget.scope != widget.scope ||
        oldWidget.name != widget.name) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    final runs = await widget.client.runList(
      widget.peerId,
      scope: widget.scope,
      name: widget.name,
    );
    if (!mounted) return;
    setState(() {
      _runs = runs;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final runs = _runs;
    return Column(
      children: [
        Row(
          children: [
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.flow_runsTitle,
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            IconButton(
              key: const ValueKey('runs-refresh'),
              tooltip: l10n.common_refresh,
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: () => unawaited(_load()),
            ),
          ],
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : runs == null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(l10n.flow_hostNoReply),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            key: const ValueKey('runs-retry'),
                            onPressed: () => unawaited(_load()),
                            child: Text(l10n.common_retry),
                          ),
                        ],
                      ),
                    )
                  : runs.isEmpty
                      ? Center(child: Text(l10n.flow_runsEmpty))
                      : ListView(
                      children: [
                        for (final run in runs!)
                          ListTile(
                            key: ValueKey('run-${run.runId}'),
                            leading: Icon(
                              run.isRunning
                                  ? Icons.play_circle_outline
                                  : Icons.check_circle_outline,
                              color: run.isRunning
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                            title: Text(
                              run.flow.isEmpty ? run.runId : run.flow,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${run.status} · ${_when(run.startedMs, l10n)}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            trailing: run.revision == null
                                ? null
                                : Text(l10n.flow_revisionLabel(run.revision!)),
                            onTap: widget.onOpenRun == null
                                ? null
                                : () => widget.onOpenRun!(
                                      run.runId,
                                      run.flow.isEmpty ? run.runId : run.flow,
                                    ),
                          ),
                      ],
                    ),
        ),
      ],
    );
  }

  String _when(int ms, AppLocalizations l10n) {
    if (ms <= 0) return l10n.flow_runsUnknownTime;
    final then = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final diff = now.difference(then);
    if (diff.inMinutes < 1) return l10n.flow_runsJustNow;
    if (diff.inHours < 1) return l10n.flow_runsMinutesAgo(diff.inMinutes);
    if (diff.inDays < 1) return l10n.flow_runsHoursAgo(diff.inHours);
    return l10n.flow_runsDaysAgo(diff.inDays);
  }
}
