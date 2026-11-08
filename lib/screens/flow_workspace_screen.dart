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
import '../peer/services/peer_agent_ids.dart';
import '../utils/layout_utils.dart';
import '../widgets/discard_changes_scope.dart';
import '../widgets/flow/flow_context_panel.dart';
import '../widgets/flow/flow_history_sheet.dart';
import '../widgets/flow/flow_new_flow_dialog.dart';
import '../widgets/flow/flow_runs_pane.dart';
import '../widgets/flow/flow_summary_tile.dart';
import 'flow_detail_screen.dart';
import 'flow_run_screen.dart';
import 'flow_start_screen.dart';

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
    this.initialAgents,
  });

  /// 为空时自己解析当前登录的主机（[HubFlow.activeHost]）。
  final String peerId;

  /// `''` 或 `lib` = 公共库；`group:<gid>` = 群库。
  final String scope;

  /// 嵌在桌面右栏里：宽屏时由列表栏自己画标题，不占一层 AppBar。
  final bool embedded;

  final HubFlow? client;

  /// Test seam：直接给定 agent 候选行，跳过本地库查询。
  @visibleForTesting
  final List<RemoteAgent>? initialAgents;

  @override
  State<FlowWorkspaceScreen> createState() => _FlowWorkspaceScreenState();
}

class _FlowWorkspaceScreenState extends State<FlowWorkspaceScreen> {
  static const double _defaultListPaneWidth = 300;
  static const double _minListPaneWidth = 220;
  static const double _minDetailWidth = 480;
  static const double _splitterWidth = 9;

  double _listPaneWidth = _defaultListPaneWidth;

  late final HubFlow _client = widget.client ?? HubFlow();
  final TextEditingController _search = TextEditingController();

  String _host = '';
  List<FlowSummary>? _flows;
  bool _loading = true;
  String? _error;
  String? _selectedName;
  List<RemoteAgent> _agents = const [];

  /// [_agents] 是按哪台主机过滤的。换主机后必须清掉重拉，否则选择器里
  /// 还是上一台主机的 agent（id 发过去主机不认识）。
  String _agentsHost = '';
  int _detailToken = 0;

  /// 编辑区有没有没保存的改动（由设计页报上来）。
  bool _editorDirty = false;
  FlowEditorController? _editor;
  bool _showRuns = false;

  /// 运行记录右侧正在看的一条。和流程库的选中一样，点另一条就换内容。
  String? _viewingRunId;
  String? _viewingRunTitle;

  /// 手机上的整页属性有没有开。ModalRoute 会把同一次系统返回通知给所有
  /// PopEntry，外层 PopScope 得靠它让设计页先关整页，不能连详情一起退掉。
  final ValueNotifier<bool> _detailPageOpen = ValueNotifier<bool>(false);

  /// 新建 / 开跑 / 运行记录 / 版本历史。盖在右侧详情上，流程库留在左边。
  Widget? _pane;
  Completer<Object?>? _paneDone;

  /// 选 Agent 再盖一层，别把正在填的开跑表单拆掉。
  Widget? _cover;
  Completer<Object?>? _coverDone;

  final FlowDraftStore _drafts = FlowDraftStore();

  /// 最近一次布局是不是宽屏（系统返回键逐级退要用）。
  bool _wide = false;

  @override
  void initState() {
    super.initState();
    // 设计页落草稿时立刻更新列表行的「有未保存草稿」标记。回调可能发生在
    // build 期间，推到下一帧再刷新。
    _drafts.drafts.addListener(_onDraftsChanged);
    unawaited(_load());
  }

  void _onDraftsChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _drafts.drafts.removeListener(_onDraftsChanged);
    _drafts.drafts.dispose();
    _detailPageOpen.dispose();
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
    final hostChanged = host != _host;
    setState(() {
      _loading = false;
      _host = host;
      if (hostChanged) {
        // 换主机：旧的 agent 行属于上一台主机，选择器不能再拿它们当候选。
        _agents = const [];
        _agentsHost = '';
      }
      _flows = flows;
      _error =
          flows == null ? AppLocalizations.of(context).flow_hostNoReply : null;
      if (_selectedName != null &&
          (flows == null || flows.every((f) => f.name != _selectedName))) {
        _selectedName = null;
      }
    });
    if (hostChanged || _agentsHost != host || _agents.isEmpty) {
      // A9-7：开机时 peer agent 还没同步，缓存会是 `[]` + 正确的 host key。
      // 空缓存不算「已缓存」，刷新时必须再拉一次。
      unawaited(_ensureAgents(host));
    }
  }

  bool _wideFor(BoxConstraints constraints) =>
      LayoutUtils.isDesktopLayout(context) && constraints.maxWidth >= 720;

  /// 列表宽度。窗口变窄时把右边编辑区留够，不让分割线把一边挤没。
  double _fitListWidth(double total) {
    final maxList = total - _minDetailWidth - _splitterWidth;
    final hi = maxList < _minListPaneWidth ? _minListPaneWidth : maxList;
    final width = _listPaneWidth < _minListPaneWidth
        ? _minListPaneWidth
        : (_listPaneWidth > hi ? hi : _listPaneWidth);
    return width;
  }

  void _dragList(double dx, double total) {
    final maxList = total - _minDetailWidth - _splitterWidth;
    final hi = maxList < _minListPaneWidth ? _minListPaneWidth : maxList;
    final next = _listPaneWidth + dx;
    final width = next < _minListPaneWidth
        ? _minListPaneWidth
        : (next > hi ? hi : next);
    if (width == _listPaneWidth) return;
    setState(() => _listPaneWidth = width);
  }

  List<FlowSummary> _visible() {
    final flows = _flows;
    if (flows == null) return const [];
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return flows;
    return flows.where((f) => f.name.toLowerCase().contains(q)).toList();
  }

  /// 切走之前先问：编辑区里有没保存的改动。
  /// 手机上同样能新建 / 复制 / 删除流程：能不能写库看主机，不看设备。
  bool get _canCreateFlows => true;

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
    final same = _selectedName == flow.name;
    // 新建 / 开跑 / 历史盖在右侧时，点一条流程就回到它的编辑页，不用先按返回。
    if (same && _pane == null && !_showRuns) return;
    unawaited(() async {
      if (!same && !await _guardDirty()) return;
      if (!mounted) return;
      _dropPane();
      setState(() {
        _showRuns = false;
        _viewingRunId = null;
        _viewingRunTitle = null;
        if (!same) {
          _detailToken++;
          _selectedName = flow.name;
        }
      });
    }());
  }

  /// 清掉右侧盖层，并让正在等结果的新建 / 开跑 / 历史结束。
  void _dropPane() {
    final done = _paneDone;
    _pane = null;
    _paneDone = null;
    if (done != null && !done.isCompleted) done.complete(null);
  }

  void _closeDetail() => unawaited(_closeDetailGuarded());

  Future<void> _closeDetailGuarded() async {
    if (_showRuns && _viewingRunId != null) {
      setState(() {
        _viewingRunId = null;
        _viewingRunTitle = null;
      });
      return;
    }
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

  Future<T?> _showPane<T>(Widget Function(void Function(T? result) finish) build) {
    final previous = _paneDone;
    if (previous != null && !previous.isCompleted) previous.complete(null);
    final done = Completer<Object?>();
    _paneDone = done;
    setState(() {
      _pane = build((result) {
        if (done.isCompleted) return;
        setState(() => _pane = null);
        if (identical(_paneDone, done)) _paneDone = null;
        done.complete(result);
      });
    });
    return done.future.then((value) => value as T?);
  }

  void _closePane() => setState(_dropPane);

  Future<T?> _showCover<T>(
      Widget Function(void Function(T? result) finish) build) {
    final previous = _coverDone;
    if (previous != null && !previous.isCompleted) previous.complete(null);
    final done = Completer<Object?>();
    _coverDone = done;
    setState(() {
      _cover = build((result) {
        if (done.isCompleted) return;
        setState(() => _cover = null);
        if (identical(_coverDone, done)) _coverDone = null;
        done.complete(result);
      });
    });
    return done.future.then((value) => value as T?);
  }

  void _closeCover() {
    final done = _coverDone;
    _coverDone = null;
    setState(() => _cover = null);
    if (done != null && !done.isCompleted) done.complete(null);
  }

  Future<void> _handlePop() async {
    if (_cover != null) {
      _closeCover();
      return;
    }
    if (_pane != null) {
      _closePane();
      return;
    }
    // 整页属性开着时，设计页自己的 PopScope 会关掉它；这次返回不能同时
    // 把详情也退回列表（一次 didPop=false 会通知到两个 PopScope）。
    if (_detailPageOpen.value) return;
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

  /// 开跑。先把定义取回来（要知道声明了哪些 inputs、哪些角色还真的用得上），
  /// 再打开独立表单页问一次。
  Future<void> _start(FlowSummary flow) async {
    final l10n = AppLocalizations.of(context);
    final fetched = await _client.get(_host, flow.name, scope: widget.scope);
    if (!mounted) return;
    if (fetched == null) {
      _snack(l10n.flow_hostNoReply);
      return;
    }
    var yaml = fetched.yaml;
    var revision = fetched.revision;
    // 新版主机在 flow_get_resp 里直接给出需要绑定的角色；老主机没给就退回
    // 客户端的保守扫描。整份定义只在这里解析一次，inputs / 角色默认值一起
    // 算好传给表单页，页面不再重复解析 YAML。
    var form = FlowRunFormData.parse(yaml,
        requiredRoles: fetched.requiredRoles);
    var plan = await _openStart(
      flowName: flow.name,
      yaml: yaml,
      roles: form.roles,
      roleDefaults: form.roleDefaults,
      inputSpecs: form.inputs,
      dirty: _editor?.dirty ?? _editorDirty,
      revision: revision,
    );
    if (plan == null || !mounted) return;
    final firstPlan = plan;
    final autoBound = widget.scope.startsWith('group:');

    // 不保存就钉住表单据以生成的那一版：否则别人在这期间存了新版，开跑用的
    // 定义和刚才填的 inputs / bindings 就不是同一份了（0 = 老主机没给版本号）。
    int? runRevision = revision > 0 ? revision : null;
    if (firstPlan.saveFirst) {
      // 用户选了「先保存成新一版再跑」：只有保存成功了才继续。
      if (!await (_editor?.save() ?? Future.value(false))) {
        _snack(l10n.flow_saveFailed);
        return;
      }
      if (!mounted) return;
      final saved = await _client.get(_host, flow.name, scope: widget.scope);
      if (!mounted) return;
      if (saved == null) {
        _snack(l10n.flow_hostNoReply);
        return;
      }
      yaml = saved.yaml;
      revision = saved.revision;
      form = FlowRunFormData.parse(yaml, requiredRoles: saved.requiredRoles);
      // 表单是照旧版本生成的，草稿里新增的 role 节点可能要多一条绑定。带着
      // 刚填好的值再问一次，别等主机跑到那个节点才报「角色没有绑定 Agent」。
      final missing = autoBound
          ? <String>[]
          : <String>[
              for (final role in form.roles)
                if (!firstPlan.bindings.containsKey(role)) role,
            ];
      if (missing.isNotEmpty) {
        final again = await _openStart(
          flowName: flow.name,
          yaml: yaml,
          roles: form.roles,
          roleDefaults: form.roleDefaults,
          inputSpecs: form.inputs,
          initialInputs: firstPlan.inputs,
          initialBindings: firstPlan.bindings,
          dirty: false,
          revision: revision,
        );
        if (again == null || !mounted) return;
        plan = again;
      }
      // 钉住刚保存下来的那一版（表单已经照它重建），别让期间别人又存的新版
      // 混进来；老主机没给版本号时不钉。
      runRevision = revision > 0 ? revision : null;
    }
    final result = await _client.start(
      _host,
      scope: widget.scope,
      name: flow.name,
      revision: runRevision,
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
    _showRun(runId, flow.name);
  }

  Future<FlowStartPlan?> _openStart({
    required String flowName,
    required String yaml,
    required List<String> roles,
    required Map<String, String> roleDefaults,
    required List<FlowInputSpec> inputSpecs,
    required bool dirty,
    required int revision,
    Map<String, String> initialInputs = const {},
    Map<String, String> initialBindings = const {},
  }) {
    return _showPane<FlowStartPlan>((finish) => FlowStartScreen(
          flowName: flowName,
          yaml: yaml,
          roles: roles,
          roleDefaults: roleDefaults,
          inputSpecs: inputSpecs,
          dirty: dirty,
          scope: widget.scope,
          revision: revision,
          initialInputs: initialInputs,
          initialBindings: initialBindings,
          onPickAgent: _pickAgent,
          onSubmit: finish,
          onDismiss: () => finish(null),
          embedded: true,
        ));
  }

  void _showRun(String runId, String title) {
    setState(() {
      _showRuns = true;
      _viewingRunId = runId;
      _viewingRunTitle = title;
    });
  }

  /// 拉取并缓存某台主机的 agent 候选。换主机时调用方会先把缓存清空。
  Future<void> _ensureAgents(String peerId) async {
    if (peerId.isEmpty) return;
    // A9-7：空列表是「名单还没同步过来」，不是缓存命中。只有真正拿到过
    // 非空候选才按 host key 跳过。
    if (_agentsHost == peerId && _agents.isNotEmpty) return;
    final all = widget.initialAgents ??
        await LocalDatabaseService().getAllRemoteAgents();
    // 拉取期间主机又切了：这批结果属于旧主机，丢掉。
    final current = _host.isNotEmpty ? _host : widget.peerId;
    if (!mounted || peerId != current) return;
    setState(() {
      _agentsHost = peerId;
      _agents =
          all.where((a) => a.isPeerAgent && a.sourcePeerId == peerId).toList();
    });
  }

  /// 打开 Agent 选择器，返回选中的 **Hub 侧 agent id**。
  ///
  /// 只列这个流程所在主机的 peer agent；写入 `bindings` 时用 Hub id，而不是
  /// 本机行 id。老行是 `peeragent_<peer>_<remote>`，设计页（[FlowDesignScreen]）
  /// 已经转过，这里必须用同一套逻辑，否则开跑时主机会收到一个它不认识的 id。
  Future<String?> _pickAgent() async {
    final peerId = _host.isNotEmpty ? _host : widget.peerId;
    // 主机可能刚切过（_load 是异步的），候选必须和当前主机一致；空缓存
    // 也要重拉（A9-7）。
    if (_agentsHost != peerId || _agents.isEmpty) {
      await _ensureAgents(peerId);
      if (!mounted) return null;
    }
    final agents = _agents;
    final picked = await _showCover<JadeSlipAgentPick>((finish) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: kToolbarHeight,
            child: Row(
              children: [
                IconButton(
                  tooltip: AppLocalizations.of(context).common_back,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => finish(null),
                ),
                Expanded(
                  child: Text(
                    AppLocalizations.of(context).flow_executorPickAgent,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: JadeSlipAgentList(
                agents: agents,
                onPick: finish,
              ),
            ),
          ),
        ],
      );
    });
    if (picked == null) return null;
    final agent = agents.where((a) => a.id == picked.id).firstOrNull;
    // 选择弹层里还有惜宝那条（不在 _agents 里）：原样返回，沿用旧行为。
    return agent == null ? picked.id : hubAgentIdOf(agent);
  }

  Future<void> _create({
    FlowNewSource initialSource = FlowNewSource.blank,
    String? initialSourceName,
  }) async {
    // 工作台进页面时已经取过 flow_list，画廊文案直接用那份结果生成：离线时点
    // 「新建」不该再等一个 10 秒超时的往返，内置文案本来就能兜底。
    final templates = FlowTemplateCatalog.fromFlows(_flows);
    final existing = _flows?.map((f) => f.name) ?? const <String>[];
    final source = templates.isEmpty && initialSource == FlowNewSource.template
        ? FlowNewSource.blank
        : initialSource;
    final request = await _showPane<FlowNewRequest>((finish) => FlowNewFlowForm(
          existingLower: existing.map((e) => e.toLowerCase()).toSet(),
          existingNames: existing.toList(),
          templates: templates,
          initialSource: source,
          initialSourceName: initialSourceName ??
              (source == FlowNewSource.copy
                  ? existing.firstOrNull
                  : (source == FlowNewSource.template
                      ? templates.firstOrNull?.id
                      : null)),
          onResult: finish,
          onCancel: () => finish(null),
        ));
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

  /// 列表行 `⋯` 里的「复制」：直接落在复制页签，源就是这一行。
  void _duplicate(FlowSummary flow) => unawaited(_create(
        initialSource: FlowNewSource.copy,
        initialSourceName: flow.name,
      ));

  /// 列表行 `⋯` 里的「删除流程」：先确认，再让主机删库里的定义。
  /// 手机和桌面共用同一个入口，删完顺手清掉本机草稿，免得留一条指向
  /// 已不存在流程的「未保存草稿」横幅。
  Future<void> _deleteFlow(FlowSummary flow) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showConfirmDialog(
      context,
      title: l10n.flow_deleteConfirmTitle,
      message: l10n.flow_deleteConfirmBody(flow.name),
      confirmLabel: l10n.flow_listDelete,
    );
    if (ok != true || !mounted) return;
    // 正在编辑这个流程且有未保存改动：先按工作台的惯例问一次，别把草稿
    // 连同流程一起静默丢掉。
    if (_selectedName == flow.name && _editorDirty && !await _guardDirty()) {
      return;
    }
    if (!mounted) return;
    final result = await _client.delete(_host, flow.name, scope: widget.scope);
    if (!mounted) return;
    if (!result.ok) {
      _snack(result.reachable
          ? (result.error ?? l10n.flow_deleteFailed)
          : l10n.flow_hostNoReply);
      return;
    }
    if (_selectedName == flow.name) {
      // 卸载编辑页之前先让它「放弃」：dispose() 的 flush 和迟到的 edit 回包
      // 都会落草稿，顺序反了就会给已删除的流程留一条幽灵草稿。
      _editor?.abandon();
      setState(() => _selectedName = null);
    }
    await _drafts.clear(
      peerId: _host,
      scope: widget.scope,
      name: flow.name,
    );
    if (!mounted) return;
    await _load();
  }

  /// 列表行 `⋯` 里的「查看历史」：看旧版本，选中某一版就存成本地草稿，
  /// 概览页顶部会出现恢复横幅（不阻塞、不直接改库里的定义）。
  Future<void> _showHistory(FlowSummary flow) async {
    final choice = await _showPane<FlowHistoryChoice>((finish) => FlowHistorySheet(
          client: _client,
          peerId: _host,
          scope: widget.scope,
          name: flow.name,
          latest: flow.latest,
          onChosen: finish,
        ));
    if (choice == null || !mounted) return;
    await _drafts.save(
      peerId: _host,
      scope: widget.scope,
      name: flow.name,
      yaml: choice.yaml,
      baseRevision: flow.latest,
    );
    if (!mounted) return;
    _select(flow);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = _wideFor(constraints);
        _wide = wide;
        final showingNarrowDetail = !wide &&
            (_selectedName != null ||
                _pane != null ||
                _cover != null ||
                (_showRuns && _viewingRunId != null));
        final hideOuterAppBar = widget.embedded && wide;
        // 只有真的要自己处理时才拦返回：窄屏详情（先退回列表）或编辑区
        // 有未保存改动。列表态且干净就放行，别无条件吃掉 iOS 侧滑 / 原生 pop。
        final intercept = showingNarrowDetail || _editorDirty;
        final canPopNatively =
            !intercept && !widget.embedded && Navigator.of(context).canPop();
        return PopScope<Object?>(
          canPop: canPopNatively,
          onPopInvokedWithResult: (didPop, _) => _onPop(didPop),
          child: Scaffold(
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
                      // 窄屏详情自己有一整页编辑区；这一栏只留列表态的新建和刷新。
                      if (!showingNarrowDetail && _canCreateFlows)
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
            body: Stack(
                        children: [
                          Positioned.fill(
                            child: _loading
                                ? const Center(child: CircularProgressIndicator())
                                : _error != null
                                    ? _buildError(l10n)
                                    : wide
                                ? Row(
                                    children: [
                                      SizedBox(
                                        key: const ValueKey(
                                            'flow-library-pane'),
                                        width: _fitListWidth(
                                            constraints.maxWidth),
                                        child: _buildListPane(l10n,
                                            showHeader: hideOuterAppBar),
                                      ),
                                      FlowPaneSplitter(
                                        handleKey: const ValueKey(
                                            'flow-library-splitter'),
                                        onDrag: (dx) => _dragList(
                                            dx, constraints.maxWidth),
                                      ),
                                      Expanded(
                                          child: _buildDetail(l10n,
                                              showHeader: true)),
                                    ],
                                  )
                                : showingNarrowDetail
                                    ? _buildDetail(l10n, showHeader: false)
                                    : _buildListPane(l10n, showHeader: false),
                          ),
                          if (_pane != null)
                            Positioned(
                              left: wide
                                  ? _fitListWidth(constraints.maxWidth) +
                                      _splitterWidth
                                  : 0,
                              right: 0,
                              top: 0,
                              bottom: 0,
                              child: Material(
                                color: Theme.of(context).colorScheme.surface,
                                child: _pane,
                              ),
                            ),
                          if (_cover != null)
                            Positioned(
                              left: wide
                                  ? _fitListWidth(constraints.maxWidth) +
                                      _splitterWidth
                                  : 0,
                              right: 0,
                              top: 0,
                              bottom: 0,
                              child: Material(
                                color: Theme.of(context).colorScheme.surface,
                                child: _cover,
                              ),
                            ),
                        ],
                      ),
          ),
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
                onSelected: (_) {
                  _dropPane();
                  setState(() => _showRuns = false);
                },
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                key: const ValueKey('tab-runs'),
                label: Text(l10n.flow_runsTab),
                selected: _showRuns,
                onSelected: (_) {
                  _dropPane();
                  setState(() => _showRuns = true);
                },
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
              selectedRunId: _viewingRunId,
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
                ? _buildEmptyLibrary(l10n)
                : ListView(
                    children: [
                      for (final flow in visible)
                        FlowSummaryTile(
                          flow: flow,
                          selected: _selectedName == flow.name,
                          hasDraft: _drafts.hasDraft(
                            peerId: _host,
                            scope: widget.scope,
                            name: flow.name,
                          ),
                          needsApproval: flow.lastRunNeedsApproval,
                          onTap: () => _select(flow),
                          onStart: () => unawaited(_start(flow)),
                          onDuplicate: () => _duplicate(flow),
                          onDelete: () => unawaited(_deleteFlow(flow)),
                          onHistory: () => unawaited(_showHistory(flow)),
                          onApproval: flow.lastRunId == null
                              ? null
                              : () => _openRun(flow.lastRunId!, flow.name),
                        ),
                    ],
                  ),
          ),
        ],
      ],
    );
  }

  /// 空库不再只是一行字：直接给「从模板新建」入口（桌面可写时）。
  Widget _buildEmptyLibrary(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final searching = _search.text.trim().isNotEmpty;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_tree_outlined, size: 40, color: scheme.outline),
          const SizedBox(height: 12),
          Text(
            searching ? l10n.flow_libraryEmpty : l10n.flow_libraryEmptyHint,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (!searching && _canCreateFlows) ...[
            const SizedBox(height: 16),
            FilledButton.tonal(
              key: const ValueKey('library-from-template'),
              onPressed: () => unawaited(
                  _create(initialSource: FlowNewSource.template)),
              child: Text(l10n.flow_libraryFromTemplate),
            ),
          ],
        ],
      ),
    );
  }

  void _openRun(String runId, String title) => _showRun(runId, title);

  Widget _buildDetail(AppLocalizations l10n, {required bool showHeader}) {
    if (_showRuns) return _buildRunDetail(l10n);
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
    final flow = _flows
            ?.where((f) => f.name == name)
            .firstOrNull ??
        FlowSummary(name: name, latest: 0, scope: widget.scope);
    return FlowDetailScreen(
      // A6-1：同名流程可能同时存在于两台主机。key 带上 _host，切主机时
      // 强制重建详情（连同它自己的 controller / 引用 / agent 缓存），
      // 不让旧 peerId 的草稿和请求混进新主机。
      key: ValueKey('flow-detail-$_detailToken-$_host'),
      peerId: _host,
      flow: flow,
      scope: widget.scope,
      client: _client,
      draftStore: _drafts,
      showHeader: showHeader,
      pageOpen: _detailPageOpen,
      onDirtyChanged: (dirty) {
        if (_editorDirty == dirty) return;
        _editorDirty = dirty;
        // PopScope 的 canPop 依赖这个值；设计页可能在 build / dispose 阶段
        // 回调，不能直接 setState，推到下一帧再刷新。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      },
      onControllerReady: (controller) {
        _editor = controller;
        controller?.onRenamed = (newName) {
          if (!mounted || _selectedName == newName) return;
          setState(() => _selectedName = newName);
          unawaited(_load());
        };
      },
    );
  }

  /// 运行记录的右侧。没有返回层，点左边另一条就换这一页。
  Widget _buildRunDetail(AppLocalizations l10n) {
    final id = _viewingRunId;
    if (id == null) {
      final scheme = Theme.of(context).colorScheme;
      return Center(
        child: Text(
          l10n.flow_runPickHint,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return FlowRunScreen(
      key: ValueKey('flow-run-$id-$_host'),
      peerId: _host,
      runId: id,
      title: _viewingRunTitle,
      embedded: true,
      onDeleted: () {
        if (!mounted) return;
        setState(() {
          _viewingRunId = null;
          _viewingRunTitle = null;
        });
      },
    );
  }
}
