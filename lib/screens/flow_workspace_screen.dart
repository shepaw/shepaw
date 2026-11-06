import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/flow/flow_draft_store.dart';
import '../controllers/flow/flow_editor_controller.dart';
import '../controllers/flow/flow_executor.dart';
import '../controllers/flow/flow_names.dart';
import '../controllers/flow/flow_templates.dart';
import '../l10n/app_localizations.dart';
import '../models/remote_agent.dart';
import '../screens/jade_slip_agent_picker.dart';
import '../services/local_database_service.dart';
import '../peer/models/flow_models.dart';
import '../peer/services/hub_flow.dart';
import '../utils/layout_utils.dart';
import '../widgets/discard_changes_scope.dart';
import '../widgets/flow/flow_new_flow_dialog.dart';
import '../widgets/flow/flow_runs_pane.dart';
import '../widgets/flow/flow_start_dialog.dart';
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
  List<RemoteAgent> _agents = const [];
  int _detailToken = 0;

  /// 编辑区有没有没保存的改动（由设计页报上来）。
  bool _editorDirty = false;
  FlowEditorController? _editor;
  bool _showRuns = false;

  final FlowDraftStore _drafts = FlowDraftStore();

  /// 设计页在窄屏详情态把 actions 发布到这里，外层工具条合并成唯一一条栏。
  final ValueNotifier<List<Widget>> _designActions =
      ValueNotifier<List<Widget>>([]);

  /// 最近一次布局是不是宽屏（系统返回键逐级退要用）。
  bool _wide = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    _designActions.dispose();
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
      _error =
          flows == null ? AppLocalizations.of(context).flow_hostNoReply : null;
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

  /// 切走之前先问：编辑区里有没保存的改动。
  /// 手机只读：新建也要收起来，别让只读端还能往库里写。
  bool get _canCreateFlows => LayoutUtils.isDesktopLayout(context);

  Future<bool> _guardDirty() async {
    if (!_editorDirty) return true;
    final l10n = AppLocalizations.of(context);
    return await showConfirmDialog(
          context,
          title: l10n.flow_draftRestoreTitle,
          message: l10n.flow_draftSwitchBody,
          confirmLabel: l10n.flow_draftSwitchGo,
        ) ==
        true;
  }

  void _select(FlowSummary flow) {
    if (_selectedName == flow.name) return;
    unawaited(() async {
      if (!await _guardDirty()) return;
      if (!mounted) return;
      setState(() {
        _detailToken++;
        _selectedName = flow.name;
      });
    }());
  }

  void _closeDetail() => unawaited(_closeDetailGuarded());

  Future<void> _closeDetailGuarded() async {
    if (!await _guardDirty()) return;
    if (!mounted) return;
    setState(() => _selectedName = null);
  }

  /// 系统返回键 / 隐含返回按钮统一走这里，按层级逐级退：
  /// 窄屏详情 → 列表（_closeDetail 内部已问过未保存草稿）；列表 → 上一页。
  void _onPop(bool didPop) {
    if (didPop) return;
    unawaited(_handlePop());
  }

  Future<void> _handlePop() async {
    if (!_wide && _selectedName != null) {
      await _closeDetailGuarded();
      return;
    }
    if (!await _guardDirty()) return;
    if (!mounted) return;
    // 桌面嵌入里这是嵌套 Navigator 的根路由，没有「上一页」可退；交给桌面外壳
    // 的菜单处理，别把根路由也 pop 掉（那样会先出现一帧空右栏）。
    if (widget.embedded) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  /// 开跑。先把定义取回来（要知道声明了哪些 inputs、有哪些角色），再问一次。
  Future<void> _start(FlowSummary flow) async {
    final l10n = AppLocalizations.of(context);
    final got = await _client.get(_host, flow.name, scope: widget.scope);
    if (!mounted) return;
    if (got == null) {
      _snack(l10n.flow_hostNoReply);
      return;
    }
    final roles = peekRoles(got.yaml);
    final plan = await showFlowStartDialog(
      context,
      flowName: flow.name,
      yaml: got.yaml,
      roles: roles,
      dirty: _editor?.dirty ?? _editorDirty,
      scope: widget.scope,
      revision: got.revision,
      onPickAgent: _pickAgent,
    );
    if (plan == null || !mounted) return;
    // 用户选了「先保存成新一版再跑」：只有保存成功了才继续开跑。
    if (plan.saveFirst && !await (_editor?.save() ?? Future.value(false))) {
      _snack(l10n.flow_saveFailed);
      return;
    }
    final result = await _client.start(
      _host,
      scope: widget.scope,
      name: flow.name,
      inputs: <String, dynamic>{...plan.inputs},
      bindings:
          plan.bindings.isEmpty ? null : <String, dynamic>{...plan.bindings},
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

  /// 打开 Agent 选择器，返回选中的 id。
  Future<String?> _pickAgent() async {
    if (_agents.isEmpty) {
      final agents = await LocalDatabaseService().getAllRemoteAgents();
      if (!mounted) return null;
      setState(() => _agents = agents);
    }
    final picked = await showJadeSlipAgentPicker(
      context,
      agents: _agents,
      title: AppLocalizations.of(context).flow_executorPickAgent,
    );
    return picked?.id;
  }

  Future<void> _create() async {
    // 工作台进页面时已经取过 flow_list，画廊文案直接用那份结果生成：离线时点
    // 「新建」不该再等一个 10 秒超时的往返，内置文案本来就能兜底。
    final templates = FlowTemplateCatalog.fromFlows(_flows);
    final request = await showNewFlowDialog(
      context,
      existing: _flows?.map((f) => f.name) ?? const [],
      templates: templates,
    );
    if (request == null || !mounted) return;
    // 新建会换掉详情区（_detailToken++），和 _select 一样要先问未保存的草稿。
    if (!await _guardDirty()) return;
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);

    // 对话框里的 existing 可能已经过期（别的设备刚建了同名流程），而老主机
    // 不认 create_only：同名会静默变成给已有流程追加一版。保存前再查一次库。
    // 「主机没应答」才不写；主机回了但没给出名单时照常写，让新主机的
    // create_only 原子裁决撞名，别把「新建」永久挡在一个坏 meta 上。
    final availability = await FlowNameGuard.check(
      _client,
      _host,
      request.name,
      scope: widget.scope,
    );
    if (!mounted) return;
    if (availability == FlowNameAvailability.taken) {
      _snack(l10n.flow_newNameTaken);
      return;
    }
    if (availability == FlowNameAvailability.unavailable) {
      _snack(l10n.flow_hostNoReply);
      return;
    }

    String yaml;
    switch (request.source) {
      case FlowNewSource.blank:
        yaml = FlowBlankFlow.skeleton(request.name);
      case FlowNewSource.template:
      case FlowNewSource.copy:
        final source = await FlowFlowFrom.sourceYaml(
          _client,
          _host,
          widget.scope,
          request.sourceName!,
        );
        if (!mounted) return;
        if (source == null) {
          _snack(l10n.flow_hostNoReply);
          return;
        }
        final renamed =
            await FlowFlowFrom.rename(_client, _host, source, request.name);
        if (!mounted) return;
        if (renamed == null) {
          _snack(l10n.flow_hostNoReply);
          return;
        }
        yaml = renamed;
    }

    // `create_only`：撞名时由主机兜住，不静默变成同名流程的下一版。
    final result = await _client.save(
      _host,
      request.name,
      yaml,
      scope: widget.scope,
      createOnly: true,
    );
    if (!mounted) return;
    if (!result.ok) {
      _snack(result.reachable
          ? (result.error ?? l10n.flow_saveFailed)
          : l10n.flow_hostNoReply);
      return;
    }
    await _load();
    if (!mounted) return;
    setState(() {
      _detailToken++;
      _selectedName = request.name;
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _onPop(didPop),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = _wideFor(constraints);
          _wide = wide;
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
                      // 窄屏详情态：设计页把它的 actions 发布到 _designActions，
                      // 这里就是唯一一条栏（不再叠一条内层 AppBar）。
                      if (showingNarrowDetail)
                        ValueListenableBuilder<List<Widget>>(
                          valueListenable: _designActions,
                          builder: (context, actions, _) => Row(
                            mainAxisSize: MainAxisSize.min,
                            children: actions,
                          ),
                        )
                      else ...[
                        if (_canCreateFlows)
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
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant,
                              ),
                              Expanded(
                                  child:
                                      _buildDetail(l10n, hoistActions: false)),
                            ],
                          )
                        : showingNarrowDetail
                            ? _buildDetail(l10n, hoistActions: true)
                            : _buildListPane(l10n, showHeader: false),
          );
        },
      ),
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
                if (!_showRuns && _canCreateFlows)
                  IconButton(
                    tooltip: l10n.flow_new,
                    icon: const Icon(Icons.add),
                    onPressed: () => unawaited(_create()),
                  ),
                IconButton(
                  tooltip: l10n.common_refresh,
                  icon: const Icon(Icons.refresh),
                  // 重新取名单：画廊文案 /「已修改」标记都来自 flow_list 的
                  // description / updated_by，光 setState 不会刷新它们。
                  onPressed: () => unawaited(_load()),
                ),
              ],
            ),
          ),
        // 流程库 / 运行记录。运行记录走主机的 flow_run_list_req，不在本地记账。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              ChoiceChip(
                key: const ValueKey('tab-flows'),
                label: Text(l10n.flow_libraryTitle),
                selected: !_showRuns,
                onSelected: (_) => setState(() => _showRuns = false),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                key: const ValueKey('tab-runs'),
                label: Text(l10n.flow_runsTab),
                selected: _showRuns,
                onSelected: (_) => setState(() => _showRuns = true),
              ),
            ],
          ),
        ),
        if (_showRuns)
          Expanded(
            child: FlowRunsPane(
              client: _client,
              peerId: _host,
              scope: widget.scope,
              onOpenRun: _openRun,
            ),
          )
        else ...[
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
      ],
    );
  }

  void _openRun(String runId, String title) {
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FlowRunScreen(peerId: _host, runId: runId, title: title),
    )));
  }

  Widget _buildDetail(AppLocalizations l10n, {required bool hoistActions}) {
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
      draftStore: _drafts,
      embedded: true,
      actionsNotifier: hoistActions ? _designActions : null,
      onDirtyChanged: (dirty) => _editorDirty = dirty,
      onControllerReady: (controller) => _editor = controller,
    );
  }
}
