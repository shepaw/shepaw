import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_models.dart';
import '../../peer/services/hub_flow.dart';

/// 「最近运行」栏（M8'）。
///
/// 数据来自主机的 `flow_run_list_req` —— 元信息随运行快照落盘，所以主机重启、
/// 运行结束之后仍然列得出来。不在这台设备上开过的运行也能看到。
///
/// 分组口径：**需要你处理**（等待审批 / 卡住）置顶，其次运行中，最后已结束。
/// 概览页传 [limit] 只取最近几条并收起标题栏。
class FlowRunsPane extends StatefulWidget {
  const FlowRunsPane({
    super.key,
    required this.client,
    required this.peerId,
    this.scope = '',
    this.name = '',
    this.onOpenRun,
    this.selectedRunId,
    this.limit,
    this.showHeader = true,
    this.onClose,
    this.onEdit,
    this.executionHistory = false,
  });

  final HubFlow client;
  final String peerId;

  /// 为空表示不过滤。
  final String scope;
  final String name;

  final void Function(String runId, String title)? onOpenRun;

  /// 右侧正在看的那条。点另一条直接换过去，不用先返回。
  final String? selectedRunId;

  /// 只显示最近 N 条（概览页用）。
  final int? limit;
  final bool showHeader;

  /// 嵌在右侧时的返回。运行记录栏不传。
  final VoidCallback? onClose;

  /// 执行历史页进入这个流程的编辑页。不传就不显示编辑图标。
  final VoidCallback? onEdit;

  /// 某个流程的执行历史：标题用「执行历史」，每一行优先展示开跑时填的标题。
  /// 这一页可以按标题 / 状态搜索，也可以按分组筛选。
  final bool executionHistory;

  @override
  State<FlowRunsPane> createState() => _FlowRunsPaneState();
}

enum _ExecFilter {
  all,
  attention,
  running,
  finished;

  FlowRunGroup? get group => switch (this) {
        _ExecFilter.all => null,
        _ExecFilter.attention => FlowRunGroup.attention,
        _ExecFilter.running => FlowRunGroup.running,
        _ExecFilter.finished => FlowRunGroup.finished,
      };
}

class _FlowRunsPaneState extends State<FlowRunsPane> {
  List<FlowRunSummary>? _runs;
  bool _loading = true;
  StreamSubscription<FlowEvent>? _sub;
  final TextEditingController _search = TextEditingController();
  _ExecFilter _filter = _ExecFilter.all;

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
    _search.dispose();
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
    final heading = widget.executionHistory
        ? l10n.flow_listExecutions
        : l10n.flow_runsTitle;
    return Column(
      key: widget.executionHistory
          ? const ValueKey('flow-executions-page')
          : null,
      children: [
        if (widget.showHeader)
          Padding(
            // 刷新贴着窗口右缘。内容区左右是 16，这里把图标再让出一截。
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                if (widget.onClose != null)
                  IconButton(
                    key: const ValueKey('executions-back'),
                    tooltip: l10n.common_back,
                    icon: const Icon(Icons.arrow_back),
                    onPressed: widget.onClose,
                  )
                else
                  const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    heading,
                    style: widget.executionHistory
                        ? theme.textTheme.titleMedium
                        : theme.textTheme.labelLarge
                            ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                if (widget.onEdit != null)
                  IconButton(
                    key: const ValueKey('executions-edit'),
                    tooltip: l10n.common_edit,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: widget.onEdit,
                  ),
                IconButton(
                  key: const ValueKey('runs-refresh'),
                  tooltip: l10n.common_refresh,
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: () => unawaited(_load()),
                ),
              ],
            ),
          ),
        if (widget.executionHistory && widget.name.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                widget.name,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        if (widget.executionHistory) ...[
          _searchField(l10n),
          _filterChips(l10n),
        ],
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
                  : _listBody(runs, l10n, theme, scheme),
        ),
      ],
    );
  }

  Widget _searchField(AppLocalizations l10n) {
    final hasQuery = _search.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        key: const ValueKey('executions-search'),
        controller: _search,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: l10n.flow_executionsSearchHint,
          prefixIcon: const Icon(Icons.search),
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: hasQuery
              ? IconButton(
                  key: const ValueKey('executions-search-clear'),
                  tooltip: l10n.common_clear,
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _search.clear();
                    setState(() {});
                  },
                )
              : null,
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _filterChips(AppLocalizations l10n) {
    final items = <(_ExecFilter, String)>[
      (_ExecFilter.all, l10n.flow_executionsFilterAll),
      (_ExecFilter.attention, l10n.flow_runsGroupAttention),
      (_ExecFilter.running, l10n.flow_runsGroupRunning),
      (_ExecFilter.finished, l10n.flow_runsGroupFinished),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          for (final (filter, label) in items)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                key: ValueKey('executions-filter-${filter.name}'),
                label: Text(label),
                selected: _filter == filter,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onSelected: (_) => setState(() => _filter = filter),
              ),
            ),
        ],
      ),
    );
  }

  Widget _listBody(
    List<FlowRunSummary> runs,
    AppLocalizations l10n,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    final visible = widget.executionHistory ? _filterRuns(runs, l10n) : runs;
    if (runs.isEmpty) return Center(child: Text(l10n.flow_runsEmpty));
    if (visible.isEmpty) {
      return Center(
        child: Text(
          l10n.flow_executionsNoMatch,
          key: const ValueKey('executions-no-match'),
        ),
      );
    }
    return ListView(
      children: _grouped(visible, l10n, theme, scheme),
    );
  }

  List<FlowRunSummary> _filterRuns(
    List<FlowRunSummary> runs,
    AppLocalizations l10n,
  ) {
    final group = _filter.group;
    final query = _search.text.trim().toLowerCase();
    return [
      for (final run in runs)
        if ((group == null || run.group == group) &&
            _matchesQuery(run, l10n, query))
          run,
    ];
  }

  bool _matchesQuery(FlowRunSummary run, AppLocalizations l10n, String query) {
    if (query.isEmpty) return true;
    final revision = run.revision;
    final haystack = [
      _headline(run, l10n),
      run.inputTitle,
      run.status,
      _statusLabel(run, l10n),
      _groupLabel(run.group, l10n),
      run.runId,
      run.flow,
      if (revision != null) '$revision',
      if (revision != null) l10n.flow_revisionLabel(revision),
    ].join('\n').toLowerCase();
    return haystack.contains(query);
  }

  String _groupLabel(FlowRunGroup group, AppLocalizations l10n) =>
      switch (group) {
        FlowRunGroup.attention => l10n.flow_runsGroupAttention,
        FlowRunGroup.running => l10n.flow_runsGroupRunning,
        FlowRunGroup.finished => l10n.flow_runsGroupFinished,
      };

  String _statusLabel(FlowRunSummary run, AppLocalizations l10n) =>
      switch (run.status.toLowerCase()) {
        'running' => l10n.flow_runRunning,
        'succeeded' => l10n.flow_runSucceeded,
        'failed' => l10n.flow_runFailed,
        'cancelled' || 'canceled' => l10n.flow_runCancelled,
        'waiting_user' ||
        'waiting' ||
        'needs_user' ||
        'needs_approval' ||
        'blocked' ||
        'halted' =>
          l10n.flow_runsGroupAttention,
        _ => run.status,
      };

  String _headline(FlowRunSummary run, AppLocalizations l10n) {
    final titled = run.inputTitle.trim();
    if (titled.isNotEmpty) return titled;
    if (widget.executionHistory) return l10n.flow_executionsUntitled;
    return run.flow.isEmpty ? run.runId : run.flow;
  }

  /// 分组后按 attention → running → finished 拼行，组内保留主机给的
  /// 「最近开的排前面」顺序。
  List<Widget> _grouped(
    List<FlowRunSummary> runs,
    AppLocalizations l10n,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    final limit = widget.limit;
    final shown = limit != null && limit > 0 && runs.length > limit
        ? runs.take(limit).toList()
        : runs;
    final groups = <FlowRunGroup, List<FlowRunSummary>>{
      for (final group in FlowRunGroup.values) group: <FlowRunSummary>[],
    };
    for (final run in shown) {
      groups[run.group]!.add(run);
    }
    final out = <Widget>[];
    for (final group in FlowRunGroup.values) {
      final items = groups[group]!;
      if (items.isEmpty) continue;
      final label = _groupLabel(group, l10n);
      out.add(
        Padding(
          key: ValueKey('runs-group-${group.name}'),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: group == FlowRunGroup.attention
                  ? Colors.orange
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
      for (final run in items) {
        out.add(_row(run, l10n, theme, scheme));
      }
    }
    return out;
  }

  Widget _row(
    FlowRunSummary run,
    AppLocalizations l10n,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    final needsAction = run.group == FlowRunGroup.attention;
    final titled = run.inputTitle.trim();
    final headline = _headline(run, l10n);
    final when = '${run.status} · ${_when(run.startedMs, l10n)}';
    // 运行记录栏混着多个流程：有标题时把流程名留在副标题，免得只剩一句话不知道是谁的。
    final showFlow = !widget.executionHistory &&
        titled.isNotEmpty &&
        widget.name.isEmpty &&
        run.flow.isNotEmpty;
    return ListTile(
      key: ValueKey('run-${run.runId}'),
      selected: widget.selectedRunId == run.runId,
      leading: Icon(
        needsAction
            ? Icons.report_problem_outlined
            : run.isRunning
                ? Icons.play_circle_outline
                : Icons.check_circle_outline,
        color: needsAction
            ? Colors.orange
            : run.isRunning
                ? scheme.primary
                : scheme.onSurfaceVariant,
      ),
      title: Text(
        headline,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        showFlow ? '${run.flow} · $when' : when,
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
                titled.isNotEmpty
                    ? titled
                    : (run.flow.isEmpty ? run.runId : run.flow),
              ),
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
