import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/flow/flow_names.dart';
import '../l10n/app_localizations.dart';
import '../peer/models/flow_models.dart';
import '../peer/services/hub_flow.dart';
import '../utils/layout_utils.dart';
import '../widgets/flow/flow_new_flow_dialog.dart';
import 'flow_design_screen.dart';
import 'flow_run_screen.dart';

/// 流程库工作台：左边列表，右边一个流程的设计视图。
///
/// 这是流程库的**常驻入口**。原来的 [FlowLibraryScreen] 只能从会话列表的
/// 「工作流」折叠组进，而主机对空折叠组直接不返回
/// （`crates/api/src/folding.rs` 的 `summaries`），没跑过流程时那个组根本不
/// 渲染 —— 于是"想配流程的人找不到配流程的地方"。这里不依赖折叠组：自己用
/// [HubFlow.activeHost] 解析主机，解析不到就给一个空态。
class FlowWorkspaceScreen extends StatefulWidget {
  const FlowWorkspaceScreen({
    super.key,
    this.peerId = '',
    this.scope = '',
    this.embedded = false,
    this.client,
  });

  /// 为空时自己解析当前登录的主机（[HubFlow.activeHost]）。
  final String peerId;

  /// `''` 或 `lib` = 公共库；`group:<gid>` = 群库。
  final String scope;

  /// 嵌在桌面右栏里：宽屏时由列表栏自己画标题，不占一层 AppBar。
  final bool embedded;

  final HubFlow? client;

  @override
  State<FlowWorkspaceScreen> createState() => _FlowWorkspaceScreenState();
}

class _FlowWorkspaceScreenState extends State<FlowWorkspaceScreen> {
  static const double _listPaneWidth = 300;

  late final HubFlow _client = widget.client ?? HubFlow();
  final TextEditingController _search = TextEditingController();

  String _host = '';
  List<FlowSummary>? _flows;
  bool _loading = true;
  String? _error;
  String? _selectedName;
  int _detailToken = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    var host = widget.peerId;
    // `AppLocalizations.of` 要等 `initState` 跑完才能读，所以两个文案都在
    // await 之后再取。
    if (host.isEmpty) host = await _client.activeHost();
    if (!mounted) return;
    if (host.isEmpty) {
      setState(() {
        _loading = false;
        _error = AppLocalizations.of(context).flow_workspaceNoHost;
      });
      return;
    }
    final flows = await _client.list(host, scope: widget.scope);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _host = host;
      _flows = flows;
      _error = flows == null
          ? AppLocalizations.of(context).flow_hostNoReply
          : null;
      if (_selectedName != null &&
          (flows == null || flows.every((f) => f.name != _selectedName))) {
        _selectedName = null;
      }
    });
  }

  bool _wideFor(BoxConstraints constraints) =>
      LayoutUtils.isDesktopLayout(context) && constraints.maxWidth >= 720;

  List<FlowSummary> _visible() {
    final flows = _flows;
    if (flows == null) return const [];
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return flows;
    return flows.where((f) => f.name.toLowerCase().contains(q)).toList();
  }

  void _select(FlowSummary flow) {
    setState(() {
      _detailToken++;
      _selectedName = flow.name;
    });
  }

  void _closeDetail() {
    setState(() => _selectedName = null);
  }

  Future<void> _start(FlowSummary flow) async {
    final l10n = AppLocalizations.of(context);
    final result = await _client.start(
      _host,
      scope: widget.scope,
      name: flow.name,
    );
    if (!mounted) return;
    final runId = result.runId;
    if (!result.ok || runId == null) {
      _snack(result.reachable
          ? (result.error ?? l10n.flow_startFailed)
          : l10n.flow_hostNoReply);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          FlowRunScreen(peerId: _host, runId: runId, title: flow.name),
    ));
  }

  Future<void> _create() async {
    final name = await showNewFlowDialog(
      context,
      existing: _flows?.map((f) => f.name) ?? const [],
    );
    if (name == null || !mounted) return;
    // `create_only`：撞名时由主机兜住，不静默变成同名流程的下一版。
    final result = await _client.save(
      _host,
      name,
      FlowBlankFlow.skeleton(name),
      scope: widget.scope,
      createOnly: true,
    );
    if (!mounted) return;
    if (!result.ok) {
      _snack(result.reachable
          ? (result.error ?? AppLocalizations.of(context).flow_saveFailed)
          : AppLocalizations.of(context).flow_hostNoReply);
      return;
    }
    await _load();
    if (!mounted) return;
    setState(() {
      _detailToken++;
      _selectedName = name;
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final flows = _flows;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = _wideFor(constraints);
        final showingNarrowDetail = !wide && _selectedName != null;
        final hideOuterAppBar = widget.embedded && wide;
        return Scaffold(
          appBar: hideOuterAppBar
              ? null
              : AppBar(
                  title: Text(showingNarrowDetail
                      ? (_selectedName ?? l10n.flow_libraryTitle)
                      : l10n.flow_libraryTitle),
                  elevation: widget.embedded ? 0 : null,
                  automaticallyImplyLeading:
                      !widget.embedded && !showingNarrowDetail,
                  leading: showingNarrowDetail
                      ? BackButton(onPressed: _closeDetail)
                      : null,
                  actions: [
                    if (!showingNarrowDetail)
                      IconButton(
                        tooltip: l10n.flow_new,
                        icon: const Icon(Icons.add),
                        onPressed: () => unawaited(_create()),
                      ),
                    if (!showingNarrowDetail)
                      IconButton(
                        tooltip: l10n.common_refresh,
                        icon: const Icon(Icons.refresh),
                        onPressed: () => unawaited(_load()),
                      ),
                  ],
                ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _buildError(l10n)
                  : wide
                      ? Row(
                          children: [
                            SizedBox(
                              width: _listPaneWidth,
                              child: _buildListPane(l10n,
                                  showHeader: hideOuterAppBar),
                            ),
                            VerticalDivider(
                              width: 1,
                              color:
                                  Theme.of(context).colorScheme.outlineVariant,
                            ),
                            Expanded(child: _buildDetail(l10n)),
                          ],
                        )
                      : showingNarrowDetail
                          ? _buildDetail(l10n)
                          : _buildListPane(l10n, showHeader: false),
        );
      },
    );
  }

  Widget _buildError(AppLocalizations l10n) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_error!),
          TextButton(
            onPressed: () => unawaited(_load()),
            child: Text(l10n.common_retry),
          ),
        ],
      ),
    );
  }

  Widget _buildListPane(AppLocalizations l10n, {required bool showHeader}) {
    final visible = _visible();
    return Column(
      children: [
        if (showHeader)
          SizedBox(
            height: kToolbarHeight,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    l10n.flow_libraryTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: l10n.flow_new,
                  icon: const Icon(Icons.add),
                  onPressed: () => unawaited(_create()),
                ),
                IconButton(
                  tooltip: l10n.common_refresh,
                  icon: const Icon(Icons.refresh),
                  onPressed: () => unawaited(_load()),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            key: const ValueKey('flow-search'),
            controller: _search,
            decoration: InputDecoration(
              hintText: l10n.common_search,
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? Center(child: Text(l10n.flow_libraryEmpty))
              : ListView(
                  children: [
                    for (final flow in visible)
                      ListTile(
                        key: ValueKey('flow-row-${flow.name}'),
                        selected: _selectedName == flow.name,
                        leading: const Icon(Icons.account_tree_outlined),
                        title: Text(flow.name),
                        subtitle: Text(l10n.flow_revisionLabel(flow.latest)),
                        onTap: () => _select(flow),
                        trailing: TextButton(
                          key: ValueKey('flow-start-${flow.name}'),
                          onPressed: () => unawaited(_start(flow)),
                          child: Text(l10n.flow_startRun),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildDetail(AppLocalizations l10n) {
    final name = _selectedName;
    if (name == null) {
      final scheme = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.account_tree_outlined, size: 40, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              l10n.flow_workspaceSubtitle,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    return FlowDesignScreen(
      key: ValueKey('flow-detail-$_detailToken'),
      peerId: _host,
      name: name,
      scope: widget.scope,
      client: _client,
    );
  }
}
