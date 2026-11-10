import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../controllers/flow/flow_edit_ops.dart';
import '../controllers/flow/flow_field_catalog.dart';
import '../controllers/flow/flow_diagnostics.dart';
import '../controllers/flow/flow_draft_store.dart';
import '../controllers/flow/flow_editor_controller.dart';
import '../controllers/flow/flow_executor.dart';
import '../controllers/flow/flow_editor_notice.dart';
import '../controllers/flow/flow_outline.dart';
import '../l10n/app_localizations.dart';
import '../peer/models/flow_models.dart';
import '../peer/pouch_turn_relay.dart';
import '../peer/services/hub_flow.dart';
import '../peer/services/peer_agent_ids.dart';
import '../models/remote_agent.dart';
import '../screens/flow_start_screen.dart';
import '../screens/jade_slip_agent_picker.dart';
import '../services/local_database_service.dart';
import '../services/she_service.dart';
import '../services/local_user_identity.dart';
import '../utils/layout_utils.dart';
import '../widgets/discard_changes_scope.dart';
import '../widgets/flow/flow_context_panel.dart';
import '../widgets/flow/flow_diagnostics_panel.dart';
import '../widgets/flow/flow_header_form.dart';
import '../widgets/flow/flow_history_sheet.dart';
import '../widgets/flow/flow_inspector_header.dart';
import '../widgets/flow/flow_node_inspector.dart';
import '../widgets/flow/flow_node_tree.dart';
import '../widgets/flow/flow_outline_menu.dart';
import '../widgets/flow/flow_outline_tree.dart';
import '../widgets/flow/flow_yaml_editor.dart';

enum _RightView { properties, source, history, agent, preview }

/// 流程设计视图（方案 C.3–C.5）：节点树 + 检查器改字段 + 与上一版的差异 + 演练。
///
/// App 不解析 YAML：每次改动都发给 Hub（`flow_edit_req`），用回来的节点树重画；
/// 不合法的地方在诊断里。保存才写进流程库成为新的 revision。
///
/// 草稿状态在 [FlowEditorController] 里，这一层只管画布、属性侧栏、源码对话框
/// 和「点选 + 说话」。诊断贴在组件列表顶部；侧栏只编辑当前组件或流程设置。
class FlowDesignScreen extends StatefulWidget {
  const FlowDesignScreen({
    super.key,
    required this.peerId,
    required this.name,
    this.scope = '',
    this.client,
    this.stepInterval = const Duration(milliseconds: 350),
    this.groupId = '',
    this.sessionId = '',
    this.talk,
    this.draftStore,
    this.onDirtyChanged,
    this.onControllerReady,
    this.embedded = false,
    this.chromeInParent = false,
    this.onBindSettings,
    this.restoreRequests,
    this.pageOpen,
    this.onOpenExecutions,
    this.hasRestorableDraft = false,
    this.onRestoreDraft,
    this.onDiscardDraft,
  });

  final String peerId;
  final String name;
  final String scope;
  final HubFlow? client;

  /// 未保存草稿的本地暂存。为 null 时不暂存。
  final FlowDraftStore? draftStore;

  /// 草稿状态变了通知外层（工作台要在切流程前拦一下）。
  final void Function(bool dirty)? onDirtyChanged;

  /// 把 controller 交给工作台，好让「开跑对话框」能读到 dirty 并请求保存。销毁时
  /// 回传 null，免得工作台拿着一个已 dispose 的 controller。
  final void Function(FlowEditorController? controller)? onControllerReady;

  /// 嵌在工作台详情区里：不画自己的 AppBar（外层已经有标题）。
  final bool embedded;

  /// 外层标题栏负责流程名和执行历史。工具条就不再重复。
  final bool chromeInParent;

  /// 把「打开流程设置」交给外层标题栏。点标题时调用。
  final void Function(VoidCallback openSettings)? onBindSettings;

  /// 详情页草稿横幅点「恢复」时 +1；设计页等控制器载入完草稿再恢复。
  final ValueNotifier<int>? restoreRequests;

  /// 手机整页属性有没有开。外层工作台的 PopScope 靠它避免「一次系统返回
  /// 同时关掉整页和整个详情」——ModalRoute 会把 didPop=false 发给所有
  /// PopEntry，两个 PopScope 都会收到。
  final ValueNotifier<bool>? pageOpen;

  /// 打开这个流程的执行历史。工作台把它盖在右侧；不传就不显示这一项。
  final VoidCallback? onOpenExecutions;

  /// 本地还有一份上次没保存的草稿。提示放进工具条，不另占一行。
  final bool hasRestorableDraft;

  /// 把那份草稿载入当前编辑。
  final VoidCallback? onRestoreDraft;

  /// 丢掉那份草稿。
  final VoidCallback? onDiscardDraft;

  /// 演练动画每一步的间隔。
  final Duration stepInterval;

  /// 有群就有"点选 + 说话"（C.3）：长按节点选中，对着它说一句，交给群主改。
  /// 没有群时设计视图只能手改。
  final String groupId;
  final String sessionId;

  /// 把一句话交给群主。测试里换成假的；为空时走 [PouchTurnRelay]。
  final Future<void> Function({
    required String groupId,
    required String content,
    required Map<String, dynamic> flowContext,
    required void Function(String chunk) onChunk,
  })? talk;

  @override
  State<FlowDesignScreen> createState() => _FlowDesignScreenState();
}

class _FlowDesignScreenState extends State<FlowDesignScreen> {
  late FlowEditorController _controller;

  /// 右侧放流程设置或当前组件。点进一个流程就打开流程设置；点组件再换成那一项。
  bool _panelOpen = true;

  /// 源码、历史、选人和开跑预览都开在右侧栏，不再盖一层弹窗。
  _RightView _rightView = _RightView.properties;
  Completer<String?>? _agentWait;
  List<FlowInputSpec> _previewSpecs = const [];
  List<String> _previewRoles = const [];
  Map<String, String> _previewDefaults = const {};
  double _panelWidth = 380;
  bool _overlay = false;

  /// 手机上属性不占右栏：点节点或「流程设置」打开盖满编辑区的整页。
  /// 它是同一个 widget 树里的覆盖层，不是路由，父级 setState 和控制器通知
  /// 都能自然重建它（跨路由同步选中态会丢草稿和光标）。
  bool _pageOpen = false;

  /// 「点选 + 说话」的显式选择模式（手机上的主入口；长按仍可直接进入）。
  bool _selecting = false;
  bool _showSelectHint = false;
  bool _leaveArmed = false;
  bool _inspectorInvalid = false;

  /// 流程设置里有还没能提交的名称或运行限制。
  bool _headerBlocked = false;

  /// 第一次点走流程设置时先留在表单上，再点一次才丢掉没提交的名称。
  bool _headerLeaveArmed = false;
  int _focusNonce = 0;
  int _discardNonce = 0;
  String? _flashField;
  final FocusNode _outlineFocus = FocusNode();

  List<String> _flowRefs = const [];
  String? _flashId;
  Timer? _flashTimer;
  final Map<String, GlobalKey> _rowKeys = {};
  bool _pendingRestore = false;

  /// 换主机后旧请求（流程引用 / agent 名单）的回包不能再写进新主机状态。
  int _hostEpoch = 0;

  // 点选 + 说话（C.3）
  final Set<String> _selected = <String>{};
  final Set<String> _collapsed = <String>{};
  String? _selectedId;
  List<RemoteAgent> _agents = const [];
  final TextEditingController _composer = TextEditingController();
  final StringBuffer _reply = StringBuffer();
  bool _talking = false;

  bool get canTalk => _talkGroupId.isNotEmpty;

  /// 编排不再按设备限制：主机支持哪些 op 就放开哪些编辑能力（手机也能改）。
  /// 布局另说：[_phoneMode] 只决定属性放右栏还是放整页。
  bool get canEdit => _controller.caps.canEdit;

  /// 手机 / 窄可用宽度：属性用整页，大纲用 compact 行，不画拖拽手柄。
  /// 桌面窗口很宽、但工作台右栏只剩四五百像素时也得按窄布局来，所以除了
  /// [LayoutUtils] 的窗口判断，还用 [_body] 量到的真实可用宽度。
  double _availableWidth = 0;
  bool? _lastPhoneMode;

  bool get _phoneMode =>
      !LayoutUtils.isDesktopLayout(context) ||
      (_availableWidth > 0 && _availableWidth < 600);

  /// 只在布局真的变了时同步一次：下一帧让工具条跟上新的宽度，并在
  /// 「手机 → 桌面」切换时先交出整页里正在编辑的文本再收起。
  void _syncLayout(double width, bool phone) {
    if (_availableWidth == width && _lastPhoneMode == phone) return;
    final wasPhone = _lastPhoneMode;
    _availableWidth = width;
    _lastPhoneMode = phone;
    final closingPage = wasPhone == true && !phone && _pageOpen;
    if (closingPage) FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        if (closingPage) {
          _pageOpen = false;
          _selecting = false;
        }
      });
    });
  }

  /// 说话要发到哪个群。没直接给 `groupId` 时，群库（`group:<gid>`）本身就是群。
  /// `sessionId` 留空：主机取群 meta 的 current_session。
  String get _talkGroupId {
    if (widget.groupId.isNotEmpty) return widget.groupId;
    return widget.scope.startsWith('group:')
        ? widget.scope.substring('group:'.length)
        : '';
  }

  @override
  void initState() {
    super.initState();
    widget.onBindSettings?.call(_showFlowSettings);
    _loadPanelWidth();
    unawaited(_loadSelectHint());
    widget.restoreRequests?.addListener(_onRestoreRequest);
    _startController();
    unawaited(_loadFlowRefs());
    unawaited(_loadAgents());
  }

  static const _panelWidthKey = 'flow_context_panel_width';
  static const _selectHintKey = 'flow_editor_select_hint_seen';

  /// 手机上第一次进来提醒一次：既能点步骤编辑，也能挑几步跟群主说。
  /// 用独立的偏好键，不和只读步骤页（FlowStepsPane）共用。
  Future<void> _loadSelectHint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_selectHintKey) == true) return;
      // 只有真正要显示提示时才把偏好写成「已看过」：先在桌面 / 非群流程
      // 打开过设计页，不该让手机上的第一次提示消失。
      if (!mounted || !_phoneMode || !canTalk) return;
      setState(() => _showSelectHint = true);
      await prefs.setBool(_selectHintKey, true);
    } catch (_) {
      // 测试里没初始化偏好时直接不提示。
    }
  }

  Future<void> _loadPanelWidth() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final width = prefs.getDouble(_panelWidthKey);
      if (!mounted || width == null) return;
      setState(() => _panelWidth = width);
    } catch (_) {
      // 测试里没初始化偏好时用默认宽度。
    }
  }

  /// 属性栏宽度。布局时再按可用空间夹到两边都还剩得下。
  double _fitPanelWidth(double available) {
    const minPanel = 280.0;
    const minTree = 280.0;
    const splitter = 9.0;
    final maxPanel =
        (available - minTree - splitter).clamp(minPanel, available);
    return _panelWidth.clamp(minPanel, maxPanel);
  }

  void _rememberPanelWidth(double width) {
    if (width == _panelWidth) return;
    final next = width;
    setState(() => _panelWidth = next);
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble(_panelWidthKey, next);
      } catch (_) {}
    }());
  }

  /// 建一份绑定当前 peerId / name / scope 的 controller，并接好通知。
  void _startController() {
    _controller = FlowEditorController(
      peerId: widget.peerId,
      name: widget.name,
      scope: widget.scope,
      client: widget.client,
      stepInterval: widget.stepInterval,
      draftStore: widget.draftStore,
    );
    _controller.onNotice = _notice;
    _controller.addListener(_reportDirty);
    widget.onControllerReady?.call(_controller);
    unawaited(_controller.load());
  }

  /// 换主机 / 换流程时彻底换掉 controller：它记着旧主机的 peerId，继续用
  /// 会让保存、校验、模型选项、演练都发到上一台主机（A6-1）。
  void _restartController() {
    final old = _controller;
    old.removeListener(_reportDirty);
    old.onNotice = null;
    widget.onControllerReady?.call(null);
    old.dispose();
    _hostEpoch++;
    _flowRefs = const [];
    _agents = const [];
    _selected.clear();
    _collapsed.clear();
    _selectedId = null;
    // 换主机 / 换流程不能把上一次打开的整页、选择模式和「还有非法值」
    // 拦截态带过来，否则新流程一进来就停在别人的表单上。
    _pageOpen = false;
    _panelOpen = true;
    _rightView = _RightView.properties;
    _agentWait?.complete(null);
    _agentWait = null;
    _selecting = false;
    _showSelectHint = false;
    _leaveArmed = false;
    _inspectorInvalid = false;
    _headerBlocked = false;
    _headerLeaveArmed = false;
    _rowKeys.clear();
    _flashId = null;
    _flashTimer?.cancel();
    _flashTimer = null;
    _reply.clear();
    _lastDirty = false;
    _pendingRestore = false;
    widget.onDirtyChanged?.call(false);
    _startController();
    // didUpdateWidget 之后本来就会 rebuild，不需要再 setState 一帧。
    unawaited(_loadFlowRefs());
  }

  /// `call.flow` 的候选：同 scope 的流程库引用。排除自己（自引用一定成环）。
  Future<void> _loadFlowRefs() async {
    final epoch = _hostEpoch;
    final peerId = widget.peerId;
    final name = widget.name;
    final scope = widget.scope;
    final flows = await _controller.client.list(peerId, scope: scope);
    if (!mounted || flows == null || epoch != _hostEpoch) return;
    final prefix = scope.startsWith('group:')
        ? 'group/${scope.substring('group:'.length)}'
        : 'lib';
    setState(() {
      _flowRefs = [
        for (final f in flows)
          if (f.name != name) '$prefix/${f.name}',
      ];
    });
  }

  @override
  void didUpdateWidget(covariant FlowDesignScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A6-1：同名流程可能在两台主机上都有。切主机（或换流程 / scope）后
    // 必须重建 controller 并清掉旧主机的引用与 agent 缓存，否则所有请求
    // 仍打向旧 peerId。工作台虽然也会给详情换 ValueKey，这一层自己也要守。
    if (oldWidget.peerId != widget.peerId ||
        oldWidget.name != widget.name ||
        oldWidget.scope != widget.scope) {
      _restartController();
      return;
    }
  }

  @override
  void dispose() {
    widget.restoreRequests?.removeListener(_onRestoreRequest);
    widget.pageOpen?.value = false;
    _outlineFocus.dispose();
    _composer.dispose();
    _flashTimer?.cancel();
    _controller.removeListener(_reportDirty);
    widget.onDirtyChanged?.call(false);
    widget.onControllerReady?.call(null);
    _controller.dispose();
    super.dispose();
  }

  bool _lastDirty = false;

  void _reportDirty() {
    final dirty = _controller.dirty;
    if (dirty != _lastDirty) {
      _lastDirty = dirty;
      widget.onDirtyChanged?.call(dirty);
    }
    // 进入时不再弹「恢复草稿」对话框：概览页顶部只有一条横幅，用户明确点
    // 「恢复」才走到这里（也可能控制器还没载入完，等下一个 notify 再试）。
    _maybeRestore();
  }

  void _onRestoreRequest() {
    _pendingRestore = true;
    _maybeRestore();
  }

  void _maybeRestore() {
    if (!_pendingRestore || _controller.loading) return;
    if (_controller.restorableDraft == null) return;
    _pendingRestore = false;
    unawaited(_controller.restoreDraft());
  }

  /// 控制器只说"发生了什么"，文案在这配。
  void _notice(FlowEditorNotice notice) {
    if (!mounted) return;
    if (notice.kind == FlowEditorNoticeKind.saveConflict) {
      unawaited(_showSaveConflict(notice));
      return;
    }
    final l10n = AppLocalizations.of(context);
    final text = switch (notice.kind) {
      FlowEditorNoticeKind.hostNoReply => l10n.flow_hostNoReply,
      FlowEditorNoticeKind.editRejected => notice.raw ?? l10n.flow_editFailed,
      FlowEditorNoticeKind.saveRejected => notice.raw ?? l10n.flow_saveFailed,
      FlowEditorNoticeKind.nameTaken => l10n.flow_newNameTaken,
      FlowEditorNoticeKind.nameInvalid => switch (notice.raw) {
          'reserved' => l10n.flow_newNameReserved,
          _ => l10n.flow_newNameInvalid,
        },
      FlowEditorNoticeKind.renameLeftover =>
        notice.raw ?? l10n.flow_renameLeftover,
      FlowEditorNoticeKind.hasProblems => l10n.flow_hasProblems(notice.count),
      FlowEditorNoticeKind.saved => l10n.flow_saved(notice.count),
      FlowEditorNoticeKind.sourceInvalid => l10n.flow_hasProblems(notice.count),
      FlowEditorNoticeKind.saveConflict => notice.raw ?? l10n.flow_saveFailed,
    };
    _snack(text);
  }

  /// 保存被冲突检测拒了：给三个出口（方案「关键设计 5」）。
  Future<void> _showSaveConflict(FlowEditorNotice notice) async {
    final l10n = AppLocalizations.of(context);
    final choice = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.flow_saveFailed),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(notice.raw ?? ''),
            const SizedBox(height: 8),
            Text(l10n.flow_conflictBody(notice.count)),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('conflict-overwrite'),
            onPressed: () => Navigator.pop(dialog, 'overwrite'),
            child: Text(l10n.flow_conflictOverwrite(notice.count)),
          ),
          FilledButton(
            key: const ValueKey('conflict-save-as'),
            onPressed: () => Navigator.pop(dialog, 'saveAs'),
            child: Text(l10n.flow_conflictSaveAs),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'overwrite':
        await _controller.save(force: true);
      case 'saveAs':
        final name = await _askSaveAsName();
        if (name != null && mounted && name.isNotEmpty) {
          // 失败原因由控制器发 notice（撞名 / 主机没应答 / 保存失败），这里别
          // 再叠一条通用「保存失败」把具体原因盖掉。
          await _controller.saveAs(name);
        }
    }
  }

  Future<String?> _askSaveAsName() async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.flow_conflictSaveAs),
        content: TextField(
          key: const ValueKey('save-as-name'),
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: l10n.flow_newName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            key: const ValueKey('save-as-go'),
            onPressed: () => Navigator.pop(dialog, controller.text.trim()),
            child: Text(l10n.flow_save),
          ),
        ],
      ),
    );
    controller.dispose();
    return name;
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  // ── 检查器 ────────────────────────────────────────────────────────────────

  // ── 大纲 ──────────────────────────────────────────────────────────────────

  List<FlowOutlineRow> _rows() {
    final rows = buildFlowOutline(_controller.tree, collapsed: _collapsed);
    for (final row in rows) {
      _rowKeys.putIfAbsent(row.node.id, () => GlobalKey());
    }
    return rows;
  }

  /// 这个节点在大纲里的那一行。结构操作一律经它，好带上 `branch`。
  FlowOutlineRow? _rowFor(String id) {
    for (final row in _rows()) {
      if (row.node.id == id) return row;
    }
    return null;
  }

  /// 诊断按节点归堆。诊断的 `at` 是路径（`l/t`），树的 `key` 带轮次（`l#0/t`），
  /// 不能直接比；但 id 全局唯一，取最后一段按 id 匹配。
  Map<String, int> _errorCounts() {
    final out = <String, int>{};
    for (final d in _controller.diagnostics) {
      if (!d.isError) continue;
      // 用和面板同一个解析规则：头部 / 全局诊断不该算到某个假节点 id 上。
      final target = resolveDiagnostic(d, _controller.tree);
      if (target is! NodeTarget) continue;
      out[target.nodeId] = (out[target.nodeId] ?? 0) + 1;
    }
    return out;
  }

  /// 点一条诊断：跳到出问题的节点（展开它的祖先并选中）。
  void _locate(FlowDiagnosticTarget target) {
    switch (target) {
      case NodeTarget(:final nodeId):
        if (!_confirmHeaderLeave()) return;
        if (!_confirmLeave()) return;
        setState(() {
          // 祖先都展开，否则目标还折叠着看不见。
          for (final row in _rows()) {
            if (row.node.find((n) => n.id == nodeId) != null) {
              _collapsed.remove(row.node.id);
            }
          }
          _selectedId = nodeId;
          _flashId = nodeId;
          _flashField = _fieldForHint(
            _nodeById(nodeId),
            target.field,
          );
          // 诊断「定位」在手机上也要打开整页表单，否则只滚到节点却没得改。
          if (_phoneMode) {
            _pageOpen = true;
            _panelOpen = false;
          } else {
            _panelOpen = true;
          }
          _leaveArmed = false;
        });
        _flashTimer?.cancel();
        _flashTimer = Timer(const Duration(milliseconds: 1500), () {
          if (mounted) {
            setState(() {
              _flashId = null;
              _flashField = null;
            });
          }
        });
        // 展开后等一帧，大纲重排完了再滚过去。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final ctx = _rowKeys[nodeId]?.currentContext;
          if (ctx != null) {
            unawaited(Scrollable.ensureVisible(
              ctx,
              duration: const Duration(milliseconds: 250),
              alignment: 0.3,
            ));
          }
        });
      case HeaderTarget():
        _showFlowSettings();
      case GlobalTarget():
        break;
    }
  }

  void _toggleCollapse(FlowOutlineRow row) {
    setState(() {
      if (!_collapsed.add(row.node.id)) _collapsed.remove(row.node.id);
    });
  }

  /// 新建一个 task 的默认体。带上流程里的第一个角色，新建后就不会立刻多一条
  /// 「缺执行者」诊断（方案要求新建一步后至多 1 条诊断）。
  Map<String, dynamic> _newStep() {
    final roles = peekRoles(_controller.yaml);
    final body = <String, dynamic>{
      'prompt': AppLocalizations.of(context).flow_newStepPrompt,
    };
    if (roles.isNotEmpty) body['role'] = roles.first;
    return {
      'id': _controller.freshId('step'),
      'task': body,
    };
  }

  void _addAfter(FlowOutlineRow row) {
    if (!_confirmHeaderLeave()) return;
    _addAfterNow(row);
  }

  void _addAfterNow(FlowOutlineRow row) {
    unawaited(_controller.applyOps([
      FlowOutlineOps.insertAfter(row, _newStep()),
    ]));
  }

  void _move(FlowOutlineRow row, {required bool up}) {
    if (!_confirmHeaderLeave()) return;
    unawaited(_controller.applyOps([
      up ? FlowOutlineOps.moveUp(row) : FlowOutlineOps.moveDown(row),
    ]));
  }

  /// 拖放落点：发一个 move（撤销走编辑器快照），落下后选中并滚到被拖节点。
  /// 正在改流程设置、而且这一组还没能提交时，先别切走。再点一次才丢掉。
  bool _confirmHeaderLeave() {
    if (_selectedId != null) return true;
    FocusManager.instance.primaryFocus?.unfocus();
    if (!_headerBlocked) {
      _headerLeaveArmed = false;
      return true;
    }
    if (!_headerLeaveArmed) {
      setState(() => _headerLeaveArmed = true);
      return false;
    }
    _headerLeaveArmed = false;
    return true;
  }

  void _onDrop(String dragId, FlowDropTarget target) {
    if (!_confirmHeaderLeave()) return;
    if (dragId != _selectedId && !_confirmLeave()) return;
    unawaited(_controller.applyOps(FlowOutlineOps.moveTo(target)));
    setState(() => _selectedId = dragId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _rowKeys[dragId]?.currentContext;
      if (ctx != null) {
        unawaited(Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 250),
          alignment: 0.3,
        ));
      }
    });
  }

  /// 当前选中的那一行（点过检查器就算选中）。
  FlowOutlineRow? get _selectedRow =>
      _selectedId == null ? null : _rowFor(_selectedId!);

  /// 桌面快捷键。
  ///
  /// 绑在大纲自己的焦点上，不跟检查器里的 TextField 抢按键 —— 所以一律带 Alt
  /// （删除除外）。
  Widget _outlineShortcuts(Widget child) {
    return Focus(
      focusNode: _outlineFocus,
      autofocus: true,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () =>
              _shortcutMove(up: true),
          const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () =>
              _shortcutMove(up: false),
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
              _shortcutOutdent,
          const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
              _shortcutIndent,
          const SingleActivator(LogicalKeyboardKey.keyN, alt: true):
              _shortcutAddAfter,
          const SingleActivator(LogicalKeyboardKey.delete): _shortcutDelete,
          const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
              _shortcutUndo,
          const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
              _shortcutUndo,
          const SingleActivator(LogicalKeyboardKey.keyZ,
              control: true, shift: true): _shortcutRedo,
          const SingleActivator(LogicalKeyboardKey.keyZ,
              meta: true, shift: true): _shortcutRedo,
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              _moveSelection(up: true),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              _moveSelection(up: false),
          const SingleActivator(LogicalKeyboardKey.enter): _focusPanel,
          const SingleActivator(LogicalKeyboardKey.escape): _onEscape,
        },
        child: child,
      ),
    );
  }

  void _shortcutUndo() {
    if (_controller.canUndo) unawaited(_controller.undo());
  }

  void _shortcutRedo() {
    if (_controller.canRedo) unawaited(_controller.redo());
  }

  void _shortcutMove({required bool up}) {
    final row = _selectedRow;
    if (row == null) return;
    if (up ? !row.canMoveUp : !row.canMoveDown) return;
    _move(row, up: up);
  }

  void _shortcutOutdent() {
    final row = _selectedRow;
    if (row == null || !row.canOutdent) return;
    unawaited(_controller.applyOps([FlowOutlineOps.outdent(row)]));
  }

  void _shortcutIndent() {
    final row = _selectedRow;
    final previous = row?.previousSibling;
    if (row == null || previous == null) return;
    // 只有 seq 是纯顺序、移进去不改语义，可以直接生效；par / loop / map 会引入
    // 并发 / 重复 / 逐项语义，交给菜单把选项写清楚再让用户挑。
    if (previous.kind == 'seq') {
      unawaited(_controller.applyOps([FlowOutlineOps.moveIntoPrevious(row)]));
      return;
    }
    final anchor = _rowKeys[row.node.id]?.currentContext ?? context;
    unawaited(_rowMenu(row, anchor));
  }

  void _shortcutAddAfter() {
    final row = _selectedRow;
    if (row == null) return;
    _addAfter(row);
  }

  void _shortcutDelete() {
    final row = _selectedRow;
    if (row == null) return;
    unawaited(_delete(row));
  }

  /// 载入某一版当草稿：走和源码「用这份」一样的校验 + 采纳路径，树和诊断一起换。
  Future<void> _openHistory() async {
    if (!_confirmHeaderLeave()) return;
    if (!_confirmLeave()) return;
    _openRight(_RightView.history);
  }

  Future<void> _rowMenu(
    FlowOutlineRow row,
    BuildContext anchor, {
    Offset? position,
  }) async {
    final choice = await showFlowOutlineMenu(
      anchor,
      row: row,
      canRetype: _controller.caps.canRetype,
      position: position,
      // 窄大纲列会把上移 / 下移收进 ⋯，菜单里始终留着这两项。
      includeMove: true,
    );
    if (choice == null || !mounted) return;
    await _applyMenuChoice(row, choice);
  }

  Future<void> _applyMenuChoice(
    FlowOutlineRow row,
    FlowOutlineMenuChoice choice,
  ) async {
    if (!_confirmHeaderLeave()) return;
    final step = _newStep;
    switch (choice.action) {
      case FlowOutlineMenuAction.insertAfter:
        _addAfterNow(row);
      case FlowOutlineMenuAction.insertChild:
        await _controller.applyOps([
          FlowOutlineOps.insertChild(row.node, step(), branch: choice.branch),
        ]);
      case FlowOutlineMenuAction.wrap:
        await _controller.applyOps([
          FlowEditOps.wrap(
            nodeId: row.node.id,
            kind: choice.kind!,
            wrapperId: _controller.freshId(choice.kind!),
          ),
        ]);
      case FlowOutlineMenuAction.unwrap:
        await _controller.applyOps([FlowEditOps.unwrap(row.node.id)]);
      case FlowOutlineMenuAction.retype:
        await _controller.applyOps([FlowOutlineOps.retype(row, choice.kind!)]);
      case FlowOutlineMenuAction.delete:
        await _deleteNow(row);
      case FlowOutlineMenuAction.moveIntoPrevious:
        await _controller.applyOps([FlowOutlineOps.moveIntoPrevious(row)]);
      case FlowOutlineMenuAction.wrapWithPrevious:
        await _controller.applyOps(FlowOutlineOps.wrapWithPrevious(
          row,
          choice.kind!,
          _controller.freshId(choice.kind!),
        ));
      case FlowOutlineMenuAction.moveToBranch:
        await _controller.applyOps([
          FlowOutlineOps.moveToBranch(row, choice.branch!),
        ]);
      case FlowOutlineMenuAction.outdent:
        await _controller.applyOps([FlowOutlineOps.outdent(row)]);
      case FlowOutlineMenuAction.moveUp:
        _move(row, up: true);
      case FlowOutlineMenuAction.moveDown:
        _move(row, up: false);
    }
  }

  Future<void> _delete(FlowOutlineRow row) async {
    if (!_confirmHeaderLeave()) return;
    await _deleteNow(row);
  }

  Future<void> _deleteNow(FlowOutlineRow row) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showConfirmDialog(
      context,
      title: l10n.flow_inspectorDelete,
      message: l10n.flow_outlineDeleteBody(row.node.id),
      confirmLabel: l10n.flow_inspectorDelete,
    );
    if (ok != true || !mounted) return;
    await _controller.applyOps([FlowEditOps.delete(row.node.id)]);
  }

  bool _confirmLeave() {
    if (!_inspectorInvalid) {
      _leaveArmed = false;
      return true;
    }
    if (!_leaveArmed) {
      setState(() => _leaveArmed = true);
      return false;
    }
    setState(() {
      _discardNonce++;
      _inspectorInvalid = false;
      _leaveArmed = false;
    });
    return true;
  }

  void _selectNode(FlowNode node) {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final multi = keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight);
    if (multi && canTalk) {
      _toggleSelected(node);
      return;
    }
    if (!_confirmHeaderLeave()) return;
    if (node.id != _selectedId && !_confirmLeave()) return;
    setState(() {
      _selectedId = node.id;
      _leaveArmed = false;
      _flashId = null;
      _flashField = null;
      if (_phoneMode) {
        // 手机上属性是一整页，不再叠一层右侧浮层。
        _pageOpen = true;
        _panelOpen = false;
      } else {
        _panelOpen = true;
      }
    });
    // 手机上别抢焦点：编辑页里的输入框马上要拿焦点。
    if (!_phoneMode) _outlineFocus.requestFocus();
  }

  void _showFlowSettings() {
    if (!_confirmLeave()) return;
    setState(() {
      _selectedId = null;
      _selected.clear();
      if (_phoneMode) {
        _pageOpen = true;
        _panelOpen = false;
      } else {
        _panelOpen = true;
      }
      _leaveArmed = false;
      _flashId = null;
      _flashField = null;
    });
  }

  /// 关掉手机上的整页属性。和桌面切走节点一样：有非法值先拦一次，
  /// 再按一次才丢弃，绝不静默丢掉没生效的输入。
  void _closePhonePage() {
    // 先让字段失焦：FlowFieldEditor 只在焦点离开时把最后一段文本提交，
    // 整页一卸载 focus 监听就没了，不先交出来会丢掉刚敲的字。
    FocusManager.instance.primaryFocus?.unfocus();
    if (!_confirmHeaderLeave()) return;
    if (!_confirmLeave()) return;
    setState(() {
      _pageOpen = false;
      // 表单随整页一起卸载，别把「名称没填好」的拦截态留到下一次选节点。
      _headerBlocked = false;
      _headerLeaveArmed = false;
    });
  }

  /// 点大纲空白：取消选中。手机上不顺势弹出流程设置整页（误触面积太大）。
  void _onOutlineBlank() {
    if (_selectedId == null && _selected.isEmpty) return;
    if (_phoneMode) {
      // 和桌面一样守住非法 / 未提交的输入，只是不弹出另一张整页。
      if (!_confirmHeaderLeave()) return;
      if (!_confirmLeave()) return;
      setState(() {
        _selectedId = null;
        _selected.clear();
      });
      return;
    }
    _showFlowSettings();
  }

  /// 诊断文案里的 `prompt` / `loop.max` 对上这个节点的字段路径。
  String? _fieldForHint(FlowNode? node, String? hint) {
    if (node == null || hint == null || hint.isEmpty) return null;
    final schema = _controller.schema;
    if (schema == null) return null;
    final specs = FlowFieldCatalog.specsFor(node.kind, schema);
    for (final spec in specs) {
      if (spec.path == hint) return spec.path;
    }
    final matches = [
      for (final spec in specs)
        if (spec.path.endsWith('.$hint')) spec.path,
    ];
    return matches.length == 1 ? matches.single : null;
  }

  void _moveSelection({required bool up}) {
    final rows = _rows();
    if (rows.isEmpty) return;
    final index = rows.indexWhere((row) => row.node.id == _selectedId);
    final next = index < 0
        ? (up ? rows.length - 1 : 0)
        : (index + (up ? -1 : 1)).clamp(0, rows.length - 1);
    _selectNode(rows[next].node);
  }

  void _focusPanel() {
    if (_selectedId == null && _selected.length < 2) return;
    setState(() => _focusNonce++);
  }

  void _onEscape() {
    // 手机上整页属性自己吃掉 Esc / 返回：先关页，再谈焦点和选中。
    if (_phoneMode && _pageOpen) {
      _closePhonePage();
      return;
    }
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null && focus != _outlineFocus && focus.hasFocus) {
      _outlineFocus.requestFocus();
      return;
    }
    if (_selectedId != null || _selected.length >= 2) {
      _showFlowSettings();
      return;
    }
    if (_overlay && _panelOpen) {
      setState(() => _panelOpen = false);
    }
  }

  FlowNode? _nodeById(String id) {
    FlowNode? found;
    void walk(List<FlowNode> nodes) {
      for (final node in nodes) {
        if (node.id == id) {
          found = node;
          return;
        }
        walk(node.children);
        if (found != null) return;
      }
    }

    walk(_controller.tree);
    return found;
  }

  void _onFieldChanged(
    String nodeId,
    String path,
    Object? value, {
    required bool immediate,
  }) {
    _controller.setField(nodeId, path, value, immediate: immediate);
  }

  void _onExecutorChanged(String nodeId, Map<String, Object?> ops) {
    unawaited(_controller.setFields(nodeId, ops));
  }

  // ── 手机布局：compact 大纲 + 选择模式 ─────────────────────────────────────

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) _showSelectHint = false;
    });
  }

  void _onOutlineTap(FlowOutlineRow row) {
    if (_selecting) {
      _toggleSelected(row.node);
      return;
    }
    _selectNode(row.node);
  }

  /// 演练中 / 只读态画的是 FlowNodeTree，选择模式下点行同样只切选中。
  void _onReadonlyTap(FlowNode node) {
    if (_selecting) {
      _toggleSelected(node);
      return;
    }
    if (canEdit) {
      _selectNode(node);
    } else {
      _showReadOnlyNode(node);
    }
  }

  void _onOutlineLongPress(FlowOutlineRow row) {
    if (!canTalk) return;
    if (!_selecting) setState(() => _selecting = true);
    _toggleSelected(row.node);
  }

  void _onReadonlyLongPress(FlowNode node) {
    if (!canTalk) return;
    if (!_selecting) setState(() => _selecting = true);
    _toggleSelected(node);
  }

  /// 空流程没有行可点，桌面只能靠模板 / 源码；手机上给一个明确的起点。
  void _addFirstStep() {
    if (!canEdit || !_confirmHeaderLeave()) return;
    unawaited(_controller.applyOps([
      FlowEditOps.insert(parentId: '', index: 0, step: _newStep()),
    ]));
  }

  // ── 点选 + 说话 ───────────────────────────────────────────────────────────

  void _toggleSelected(FlowNode node) {
    if (_controller.busy) return;
    // 第二项选中会把属性面板换成多选摘要，表单跟着卸掉。
    final adding = !_selected.contains(node.id);
    if (adding && _selected.length == 1) {
      if (!_confirmHeaderLeave()) return;
      if (!_confirmLeave()) return;
    }
    setState(() {
      if (!_selected.add(node.id)) _selected.remove(node.id);
    });
  }

  /// 这一轮交给群主的上下文（C.3）：`{flow: {ref}, selection: [...]}`。
  ///
  /// 主机把选中节点的原文带进群主的提示里，群主不用猜"这两个并行"指哪两个。
  Map<String, dynamic> _talkContext() {
    final reference = widget.scope.isEmpty || widget.scope == 'lib'
        ? 'lib/${widget.name}'
        : '${widget.scope}/${widget.name}';
    return {
      'flow': {'ref': reference},
      'selection': _selected.toList(),
    };
  }

  /// 打开 Agent 选择器，返回选中的 **Hub 侧 agent id**。
  ///
  /// 只列这个流程所在主机的 peer agent；写入时用 Hub id，而不是本机行 id。
  /// 老行是 `peeragent_<peer>_<remote>`，得先剥成 remote id，否则 `task.agent`
  /// 会存一个主机不认的值，模型列表也拉不对。
  Future<void> _loadAgents() async {
    if (_agents.isNotEmpty) return;
    final epoch = _hostEpoch;
    final peerId = widget.peerId;
    try {
      final all = await LocalDatabaseService().getAllRemoteAgents();
      if (!mounted || epoch != _hostEpoch || peerId != widget.peerId) return;
      setState(() => _agents =
          all.where((a) => a.isPeerAgent && a.sourcePeerId == peerId).toList());
    } catch (_) {
      // 测试里没有本机库。名字对不上就继续显示 id。
    }
  }

  String? _agentLabel(String id) => _agentFace(id)?.name;

  /// 主机只存 agent id。界面用本机名单里的名字和头像，惜宝单独认。
  FlowAgentFace? _agentFace(String id) {
    if (SheService.isSheIdentity(id)) {
      return FlowAgentFace(
        name: SheService.resolveDisplayName(
          null,
          AppLocalizations.of(context).she_name,
        ),
        avatar: SheService.sheAvatar,
      );
    }
    for (final agent in _agents) {
      if (hubAgentIdOf(agent) != id && agent.id != id) continue;
      if (SheService.isSheIdentity(agent.id, agent.metadata)) {
        return FlowAgentFace(
          name: SheService.resolveDisplayName(
            agent.name,
            AppLocalizations.of(context).she_name,
          ),
          avatar: SheService.sheAvatar,
        );
      }
      final name = agent.name.trim();
      if (name.isEmpty) return null;
      return FlowAgentFace(
        name: name,
        avatar: SheService.displayAvatar(
          id: agent.id,
          stored: agent.avatar,
          metadata: agent.metadata,
        ),
      );
    }
    return null;
  }

  Future<String?> _pickAgent() async {
    await _loadAgents();
    if (!mounted) return null;
    final wait = Completer<String?>();
    _agentWait?.complete(null);
    _agentWait = wait;
    _openRight(_RightView.agent);
    final pickedId = await wait.future;
    if (pickedId == null || !mounted) return null;
    if (pickedId == SheService.sheId) return SheService.sheId;
    final agent = _agents.where((a) => a.id == pickedId).firstOrNull;
    return agent == null ? pickedId : hubAgentIdOf(agent);
  }

  void _openRight(_RightView view) {
    setState(() {
      _rightView = view;
      if (_phoneMode) {
        _pageOpen = true;
      } else {
        _panelOpen = true;
      }
    });
  }

  void _closeRight() {
    final wait = _agentWait;
    _agentWait = null;
    setState(() => _rightView = _RightView.properties);
    if (wait != null && !wait.isCompleted) wait.complete(null);
  }

  Future<void> _useHistory(FlowHistoryChoice choice) async {
    _closeRight();
    final checked =
        await _controller.client.validate(widget.peerId, choice.yaml);
    if (!mounted) return;
    await _controller.applySource(choice.yaml, checked);
  }

  Future<void> _talk() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _talking) return;
    await _controller.flush();
    if (!mounted) return;
    setState(() {
      _talking = true;
      _reply.clear();
    });
    try {
      final send = widget.talk;
      if (send == null) {
        await PouchTurnRelay.instance.forwardGroup(
          hostPeerId: widget.peerId,
          channelId: _talkGroupId,
          content: text,
          userId: LocalUserIdentity.id,
          userName: LocalUserIdentity.displayName,
          flowContext: _talkContext(),
          onStreamChunk: (_, __, chunk) {
            if (!mounted) return;
            setState(() => _reply.write(chunk));
          },
          onAgentDone: (_, __, ___) => unawaited(_controller.reload()),
        );
      } else {
        await send(
          groupId: _talkGroupId,
          content: text,
          flowContext: _talkContext(),
          onChunk: (chunk) {
            if (!mounted) return;
            setState(() => _reply.write(chunk));
          },
        );
        // 假中继没有 onAgentDone：自己刷新一次。
        unawaited(_controller.reload());
      }
    } catch (error) {
      if (mounted) _snack('$error');
    } finally {
      if (mounted) setState(() => _talking = false);
    }
    _composer.clear();
  }

  // ── 界面 ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pageOpen = _phoneMode && _pageOpen;
    if (widget.pageOpen?.value != pageOpen) {
      widget.pageOpen?.value = pageOpen;
    }
    final content = ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        return Scaffold(
          // 嵌在详情页里时，外层已经有标题；这里不再叠第二条 AppBar。
          appBar: widget.embedded
              ? null
              : AppBar(
                  title: _settingsTitle(l10n),
                  automaticallyImplyLeading: false,
                  actions: [
                    if (widget.onOpenExecutions != null)
                      _executionsButton(l10n, iconOnly: false),
                  ],
                ),
          body: Stack(
            children: [
              Column(
                children: [
                  _toolbar(context, l10n, c),
                  if (c.rehearsal.active) _rehearsalBanner(l10n),
                  if (_phoneSelectBar(l10n) case final bar?) bar,
                  Expanded(child: _body(l10n)),
                  if (_talkBar(l10n) case final bar?) bar,
                ],
              ),
              // 属性整页盖住工具条、大纲和说话条：编辑时只面对一张表单。
              if (pageOpen) Positioned.fill(child: _phonePropertiesPage(l10n)),
            ],
          ),
        );
      },
    );
    // 只有手机整页打开时才挂 PopScope：系统返回先关这一页，别把没保存的
    // 草稿和整屏表单一起丢掉。其余形态的 widget 树保持原样。
    if (!pageOpen) return content;
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _phoneMode && _pageOpen) _closePhonePage();
      },
      child: content,
    );
  }

  /// 手机上一条细条：说明既能点步骤编辑，也能显式进入「点选 + 说话」。
  Widget? _phoneSelectBar(AppLocalizations l10n) {
    if (!_phoneMode || !canTalk) return null;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _selecting
                  ? l10n.flow_phoneSelected(_selected.length)
                  : l10n.flow_phoneEditHint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          TextButton(
            key: const ValueKey('steps-select'),
            onPressed: _toggleSelecting,
            child:
                Text(_selecting ? l10n.flow_stepsDone : l10n.flow_stepsSelect),
          ),
        ],
      ),
    );
  }

  /// 手机上的属性整页。桌面用 [FlowContextPanel]，两者复用同一份
  /// [_propertiesPane]，所以字段、校验、即时生效和撤销粒度完全一致。
  Widget _phonePropertiesPage(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final c = _controller;
    final node = _selectedId == null ? null : _nodeById(_selectedId!);
    final title = node == null
        ? l10n.flow_headerOpen
        : '${flowKindName(l10n, node.kind)} · ${node.id}';
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: kToolbarHeight,
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey('phone-editor-close'),
                    tooltip: l10n.common_back,
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _rightView == _RightView.properties
                        ? _closePhonePage
                        : _closeRight,
                  ),
                  Expanded(
                    child: Text(title,
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (canEdit && c.dirty)
                    IconButton(
                      key: const ValueKey('phone-editor-save'),
                      tooltip: l10n.flow_save,
                      icon: const Icon(Icons.check),
                      onPressed: () => _doSave(c),
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 选人时盖住表单，不拆掉。拆掉后人选回来写不回执行者。
                  ListView(
                    key: const ValueKey('phone-properties-page'),
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    children: [_propertiesPane(l10n)],
                  ),
                  if (_rightView != _RightView.properties)
                    ColoredBox(
                      color: theme.colorScheme.surface,
                      child: _rightFill(l10n),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 工具条：保存状态在左，保存 / 演练 / 撤销在右。
  /// 流程名和执行历史在标题栏；窄屏没有标题栏时，这两项留在工具条上。
  /// 有改动时，处数贴在保存按钮左边。
  Widget _toolbar(
    BuildContext context,
    AppLocalizations l10n,
    FlowEditorController c,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        // 用真实可用宽度，不用窗口宽度：工作台右栏可能只有四五百像素。
        final width = constraints.maxWidth;
        final compact = width < 600;
        final statusText = c.saving
            ? l10n.flow_toolbarSaving
            : c.errorCount > 0
                ? l10n.flow_toolbarProblems(c.errorCount)
                : c.dirty
                    ? l10n.flow_toolbarUnsaved
                    : l10n.flow_toolbarSaved(c.revision);
        // 侧栏打开时，标题占满左侧步骤栏（和下面的卡片一样宽），
        // 操作按钮放到右侧设置栏那一列，中间留出和分割线一样的空隙。
        final split = canEdit && _panelOpen && !_phoneMode && width >= 900;
        final panelWidth = split ? _fitPanelWidth(width) : 0.0;
        final actions = _toolbarActions(l10n, c, compact);
        return Material(
          color: scheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        if (widget.hasRestorableDraft)
                          Flexible(
                            child: _toolbarLead(
                                l10n, theme, scheme, statusText, c),
                          )
                        else
                          Expanded(
                            child: _toolbarLead(
                                l10n, theme, scheme, statusText, c),
                          ),
                        if (widget.hasRestorableDraft) ...[
                          const SizedBox(width: 12),
                          Flexible(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: _draftPrompt(l10n),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (split) ...[
                  const SizedBox(width: 9),
                  SizedBox(
                    width: panelWidth,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: actions,
                      ),
                    ),
                  ),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: actions,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _toolbarActions(
    AppLocalizations l10n,
    FlowEditorController c,
    bool compact,
  ) {
    final diff = c.diff;
    final changes = diff == null ? 0 : diff.nodes.length + diff.header.length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canEdit && changes > 0)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              l10n.flow_diffSummary(changes),
              key: const ValueKey('diff-summary'),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        if (canEdit)
          FilledButton.icon(
            key: const ValueKey('save-button'),
            onPressed:
                c.loading || c.busy || !c.dirty ? null : () => _doSave(c),
            icon: c.saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check, size: 18),
            label: Text(l10n.flow_save),
          ),
        if (canEdit && !compact) ...[
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const ValueKey('rehearse-button'),
            onPressed: c.loading || c.rehearsal.active
                ? null
                : () => _startRehearsal(c),
            icon: const Icon(Icons.science_outlined, size: 18),
            label: Text(l10n.flow_rehearse),
          ),
          IconButton(
            key: const ValueKey('undo'),
            tooltip: l10n.flow_undo,
            icon: const Icon(Icons.undo),
            onPressed: c.canUndo ? c.undo : null,
          ),
          IconButton(
            key: const ValueKey('redo'),
            tooltip: l10n.flow_redo,
            icon: const Icon(Icons.redo),
            onPressed: c.canRedo ? c.redo : null,
          ),
        ],
        if (canEdit &&
            widget.onOpenExecutions != null &&
            !widget.chromeInParent)
          _executionsButton(l10n, iconOnly: true),
        if (canEdit) _moreMenu(l10n, c, compact),
      ],
    );
  }

  /// 标题栏上的流程名。点它打开流程设置。
  Widget _settingsTitle(AppLocalizations l10n, {bool expand = false}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final editable = canEdit;
    final name = Text(
      widget.name,
      style: theme.textTheme.titleMedium?.copyWith(
        color: editable ? scheme.primary : scheme.onSurface,
        fontWeight: FontWeight.w600,
        decoration: editable ? TextDecoration.underline : TextDecoration.none,
        decorationColor: scheme.primary,
      ),
      overflow: TextOverflow.ellipsis,
    );
    final row = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      children: [
        if (expand) Expanded(child: name) else name,
        if (editable) ...[
          const SizedBox(width: 4),
          Icon(Icons.tune, size: 18, color: scheme.primary),
        ],
      ],
    );
    if (!editable) return row;
    return Tooltip(
      message: l10n.flow_headerOpen,
      child: InkWell(
        key: const ValueKey('flow-title'),
        onTap: _showFlowSettings,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: row,
        ),
      ),
    );
  }

  Widget _executionsButton(AppLocalizations l10n, {required bool iconOnly}) {
    if (iconOnly) {
      return IconButton(
        key: const ValueKey('executions-open'),
        tooltip: l10n.flow_listExecutions,
        icon: const Icon(Icons.history),
        onPressed: widget.onOpenExecutions,
      );
    }
    return TextButton.icon(
      key: const ValueKey('executions-open'),
      onPressed: widget.onOpenExecutions,
      icon: const Icon(Icons.history, size: 18),
      label: Text(l10n.flow_listExecutions),
    );
  }

  /// 上次没保存的草稿。收成工具条里的一粒提示，和保存状态、操作按钮同一行。
  Widget _draftPrompt(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final onTint = scheme.onErrorContainer;
    final actionStyle = TextButton.styleFrom(
      foregroundColor: onTint,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(0, 28),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: DecoratedBox(
        key: const ValueKey('draft-banner'),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history, size: 16, color: onTint),
              const SizedBox(width: 6),
              Text(
                l10n.flow_draftBannerTitle,
                style: theme.textTheme.labelMedium?.copyWith(color: onTint),
              ),
              if (widget.onRestoreDraft != null)
                TextButton(
                  key: const ValueKey('draft-restore'),
                  style: actionStyle.copyWith(
                    textStyle: WidgetStatePropertyAll(
                      theme.textTheme.labelMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  onPressed: widget.onRestoreDraft,
                  child: Text(l10n.flow_draftBannerRestore),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    l10n.flow_draftBannerReadOnly,
                    style: theme.textTheme.labelSmall?.copyWith(color: onTint),
                  ),
                ),
              TextButton(
                key: const ValueKey('draft-discard'),
                style: actionStyle,
                onPressed: widget.onDiscardDraft,
                child: Text(l10n.flow_draftBannerDiscard),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 工具条左侧：保存状态。没有外层标题栏时，流程名也留在这里。
  Widget _toolbarLead(
    AppLocalizations l10n,
    ThemeData theme,
    ColorScheme scheme,
    String statusText,
    FlowEditorController c,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.chromeInParent && widget.embedded)
          _settingsTitle(l10n, expand: true),
        Text(
          statusText,
          key: const ValueKey('save-status'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: c.dirty || c.errorCount > 0
                ? scheme.error
                : scheme.onSurfaceVariant,
          ),
        ),
        if (!widget.embedded && c.revision > 0)
          Text(l10n.flow_revisionLabel(c.revision),
              key: const ValueKey('revision-label'),
              style: theme.textTheme.labelSmall),
      ],
    );
  }

  Widget _moreMenu(
      AppLocalizations l10n, FlowEditorController c, bool compact) {
    return PopupMenuButton<String>(
      key: const ValueKey('design-more'),
      tooltip: l10n.flow_toolbarMore,
      onSelected: (choice) => _onMenuChoice(choice, c),
      itemBuilder: (context) => [
        // 窄工具条把这三个按钮收进来（桌面仍是工具条上的按钮）。
        if (compact) ...[
          PopupMenuItem<String>(
            key: const ValueKey('menu-undo'),
            value: 'undo',
            enabled: c.canUndo,
            child: Text(l10n.flow_undo),
          ),
          PopupMenuItem<String>(
            key: const ValueKey('menu-redo'),
            value: 'redo',
            enabled: c.canRedo,
            child: Text(l10n.flow_redo),
          ),
          PopupMenuItem<String>(
            key: const ValueKey('menu-rehearse'),
            value: 'rehearse',
            enabled: !c.loading && !c.rehearsal.active,
            child: Text(l10n.flow_rehearse),
          ),
        ],
        PopupMenuItem<String>(
          key: const ValueKey('history-open'),
          value: 'history',
          enabled: canEdit && c.revision > 1,
          child: Text(l10n.flow_historyOpen),
        ),
        PopupMenuItem<String>(
          // 源码不占侧栏页签：从这里打开一个对话框。
          key: const ValueKey('yaml-bar'),
          value: 'source',
          child: Text(l10n.flow_source),
        ),
      ],
    );
  }

  void _onMenuChoice(String choice, FlowEditorController c) {
    switch (choice) {
      case 'history':
        unawaited(_openHistory());
      case 'source':
        _openSource();
      case 'undo':
        if (c.canUndo) unawaited(c.undo());
      case 'redo':
        if (c.canRedo) unawaited(c.redo());
      case 'rehearse':
        _startRehearsal(c);
    }
  }

  /// 先把焦点移走，让描述和流程设置把当前输入交出来，再看有没有没能提交的。
  bool _flushEditors() {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_inspectorInvalid || _headerBlocked) {
      setState(() {
        _leaveArmed = _inspectorInvalid;
        if (_phoneMode) {
          _pageOpen = true;
        } else {
          _panelOpen = true;
        }
      });
      return false;
    }
    return true;
  }

  void _doSave(FlowEditorController c) {
    if (!_flushEditors()) return;
    unawaited(c.save());
  }

  void _startRehearsal(FlowEditorController c) {
    // 演练的图标 / 文案与「开始运行」显式区分；演练期间顶部一直挂着提示条，
    // 选项直接摆在组件列表上方，不再占侧栏页签。
    // 先把正在编辑的输入框交出去，否则描述这类只在失焦时提交的字段进不了演练。
    if (!_flushEditors()) return;
    unawaited(c.startRehearsal());
  }

  Widget _rehearsalBanner(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('rehearsal-banner'),
      width: double.infinity,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.science_outlined, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(l10n.flow_rehearsalBanner)),
        ],
      ),
    );
  }

  Widget _body(AppLocalizations l10n) {
    final c = _controller;
    if (c.loading) return const Center(child: CircularProgressIndicator());
    if (c.loadFailed) return Center(child: Text(l10n.flow_designLoadFailed));
    final theme = Theme.of(context);
    final diff = c.diff;
    final rehearsal = c.rehearsal;
    // 诊断和演练选项贴在组件列表顶部。侧栏只放属性，开合不换页签。
    // 树的滚动位置由同一个 ListView 自己保留。
    final treePane = Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey('outline-blank'),
            behavior: HitTestBehavior.opaque,
            onTap: _onOutlineBlank,
          ),
        ),
        ListView(
          key: const ValueKey('flow-node-tree'),
          padding: const EdgeInsets.all(12),
          children: [
            if (c.diagnostics.isNotEmpty)
              FlowDiagnosticsPanel(
                diagnostics: c.diagnostics,
                tree: c.tree,
                onLocate: _locate,
              ),
            if (rehearsal.active) ...[
              _rehearsalCard(l10n, theme),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final step
                      in rehearsal.rehearsal?.steps ?? const <String>[])
                    Chip(
                      key: ValueKey('rehearse-step-$step'),
                      label: Text(step, style: const TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            // 第一次进来提醒一次：可以点步骤编辑，也可以挑几步跟群主说。
            if (_phoneMode && canTalk && _showSelectHint)
              MaterialBanner(
                key: const ValueKey('phone-select-hint'),
                content: Text(l10n.flow_stepsHint),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _showSelectHint = false),
                    child: Text(l10n.common_ok),
                  ),
                ],
              ),
            // 主机缺操作：明确说清为什么只读，别让人以为按钮坏了。
            if (!canEdit)
              Card(
                color: theme.colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    l10n.flow_readOnlyHostHint,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            // 能改就画可编辑的大纲（带分支、上移下移、加一步）；否则画只读的那棵。
            if (canEdit && !rehearsal.active)
              _outlineShortcuts(
                FlowOutlineTree(
                  rows: _rows(),
                  canEdit: true,
                  branchesLabelled: c.caps.branchesLabelled,
                  canMove: c.caps.canMove,
                  tree: c.tree,
                  dragEnabled: !c.busy && !_phoneMode,
                  compact: _phoneMode,
                  selectionMode: _selecting,
                  selectedIds: _selected,
                  onDrop: _onDrop,
                  selectedId: _selectedId,
                  errorCounts: _errorCounts(),
                  collapsed: _collapsed,
                  rowKeys: _rowKeys,
                  flashId: _flashId,
                  badgeFor: diff == null
                      ? null
                      : (row) {
                          final change = diff.of(row.node.id);
                          return switch (change?.change) {
                            FlowChange.added => (
                                l10n.flow_diffAdded,
                                Colors.green
                              ),
                            FlowChange.changed => (
                                l10n.flow_diffChanged,
                                Colors.amber
                              ),
                            _ => null,
                          };
                        },
                  onTapRow: _onOutlineTap,
                  onSecondaryTapRow: (row, position) =>
                      unawaited(_rowMenu(row, context, position: position)),
                  onToggleCollapse: _toggleCollapse,
                  onAddAfter: _addAfter,
                  onMoveUp: (row) => _move(row, up: true),
                  onMoveDown: (row) => _move(row, up: false),
                  onDelete: _delete,
                  onMenu: (row, anchor) => unawaited(_rowMenu(row, anchor)),
                  onLongPressRow: canTalk ? _onOutlineLongPress : null,
                ),
              )
            else
              FlowNodeTree(
                nodes: rehearsal.view(c.tree),
                onTapNode: _onReadonlyTap,
                onLongPressNode: canTalk ? _onReadonlyLongPress : null,
                selectedIds: _selected,
                selectionMode: _selecting,
                badgeFor: diff == null
                    ? null
                    : (node) {
                        final change = diff.of(node.id);
                        return switch (change?.change) {
                          FlowChange.added => (
                              l10n.flow_diffAdded,
                              Colors.green
                            ),
                          FlowChange.changed => (
                              l10n.flow_diffChanged,
                              Colors.amber
                            ),
                          _ => null,
                        };
                      },
              ),
            // 空流程在手机上没有行可点，给一个明确的起点（桌面靠模板 / 源码）。
            if (_phoneMode && canEdit && !rehearsal.active && _rows().isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: FilledButton.tonal(
                  key: const ValueKey('phone-add-first-step'),
                  onPressed: _addFirstStep,
                  child: Text(l10n.flow_phoneAddFirstStep),
                ),
              ),
            if (diff != null && diff.removed.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.flow_diffRemoved(
                      diff.removed.map((n) => n.id).join(', ')),
                  style: theme.textTheme.bodySmall?.copyWith(
                    decoration: TextDecoration.lineThrough,
                    color: Colors.grey,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
    final staleSelection =
        _selectedId != null && _nodeById(_selectedId!) == null;
    final staleTalk = _selected.where((id) => _nodeById(id) == null).toList();
    if (staleSelection || staleTalk.isNotEmpty) {
      final staleId = _selectedId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          if (staleId != null &&
              _selectedId == staleId &&
              _nodeById(staleId) == null) {
            _selectedId = null;
            // 手机上整页属性正显示这个被删掉的节点，退回大纲。整页会在这一
            // 帧被卸载，先让字段失焦提交，并清掉残留的拦截态，别把非法值
            // 的「再点一次」带到下一次操作里。
            if (_phoneMode) {
              FocusManager.instance.primaryFocus?.unfocus();
              _pageOpen = false;
              _selecting = false;
              _leaveArmed = false;
              _inspectorInvalid = false;
              _headerBlocked = false;
              _headerLeaveArmed = false;
            }
          }
          _selected.removeWhere((id) => _nodeById(id) == null);
        });
      });
    }
    return CallbackShortcuts(
      bindings: {
        // 面板里按 Esc 把焦点还给大纲；大纲上再按一次才取消选中。
        const SingleActivator(LogicalKeyboardKey.escape): _onEscape,
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final wide = width >= 900;
          _syncLayout(
              width, !LayoutUtils.isDesktopLayout(context) || width < 600);
          // 手机上属性是 build 外层 Stack 里的整页，这里不再画右栏 / 浮层。
          final showPanel = canEdit && _panelOpen && !_phoneMode;
          if (_overlay != !wide) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _overlay == wide) setState(() => _overlay = !wide);
            });
          }
          final panelWidth = _fitPanelWidth(width);
          final panel = showPanel ? _rightPanel(l10n) : null;
          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: treePane),
                if (panel != null) ...[
                  FlowPaneSplitter(
                    onDrag: (dx) =>
                        _rememberPanelWidth(_fitPanelWidth(width) - dx),
                  ),
                  SizedBox(
                    key: const ValueKey('flow-properties-pane'),
                    width: panelWidth,
                    child: panel,
                  ),
                ],
              ],
            );
          }
          final overlayWidth =
              width < 600 ? width : (width * 0.85).clamp(0, 380).toDouble();
          return Stack(
            children: [
              Positioned.fill(child: treePane),
              if (panel != null)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: overlayWidth,
                  child: Material(elevation: 4, child: panel),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _propertiesPane(AppLocalizations l10n) {
    final c = _controller;
    // 手机上的多选是「点选 + 说话」用的；退出选择模式后点节点要能直接改字段，
    // 不能被多选摘要挡住（桌面 Ctrl 多选仍然显示摘要）。
    if (_selected.length >= 2 && !_phoneMode) return _multiSummary(l10n);
    final selected = _selectedId == null ? null : _nodeById(_selectedId!);
    final schema = c.schema;
    if (selected == null || schema == null) {
      return FlowHeaderForm(
        controller: c,
        readOnly: !c.caps.canEditHeader || c.rehearsal.active,
        onPickAgent: _pickAgent,
        onPreviewStart: ({
          required inputSpecs,
          required roles,
          required roleDefaults,
        }) async {
          setState(() {
            _previewSpecs = inputSpecs;
            _previewRoles = roles;
            _previewDefaults = roleDefaults;
          });
          _openRight(_RightView.preview);
        },
        agentLabel: _agentLabel,
        tree: c.tree,
        onBlocked: (blocked) {
          _headerBlocked = blocked;
          if (!blocked) _headerLeaveArmed = false;
        },
      );
    }
    final nodeDiags = [
      for (final d in c.diagnostics)
        if (resolveDiagnostic(d, c.tree) case NodeTarget(:final nodeId))
          if (nodeId == selected.id) d,
    ];
    final problems = [for (final d in nodeDiags) d.message];
    return FlowNodeInspector(
      key: ValueKey('inspector-${selected.id}'),
      node: selected,
      schema: schema,
      row: _rowFor(selected.id),
      canRetype: c.caps.canRetype,
      readOnly: false,
      rehearsalLocked: c.rehearsal.active,
      roles: peekRoles(c.yaml),
      onPickAgent: _pickAgent,
      agentOf: _agentFace,
      peerId: widget.peerId,
      tree: c.tree,
      yaml: c.yaml,
      flowRefs: _flowRefs,
      problems: problems,
      problemIsError: nodeDiags.isEmpty || nodeDiags.any((d) => d.isError),
      rejections: {
        for (final spec in FlowFieldCatalog.specsFor(selected.kind, schema))
          if (c.rejection(selected.id, spec.path) case final reason?)
            spec.path: reason,
      },
      flashField: _flashField,
      changedFields: {
        for (final change
            in c.diff?.of(selected.id)?.fields ?? const <FlowFieldChange>[])
          change.field,
      },
      showInvalidBanner: _leaveArmed,
      focusNonce: _focusNonce,
      discardNonce: _discardNonce,
      onValidity: (invalid) {
        if (_inspectorInvalid == invalid) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _inspectorInvalid = invalid);
        });
      },
      onFieldChanged: (path, value, {required immediate}) =>
          _onFieldChanged(selected.id, path, value, immediate: immediate),
      onExecutorChanged: (ops) => _onExecutorChanged(selected.id, ops),
      onDescChanged: (desc) =>
          _onFieldChanged(selected.id, 'desc', desc, immediate: true),
      onMenuChoice: (choice) {
        final row = _rowFor(selected.id);
        if (row == null) return;
        unawaited(_applyMenuChoice(row, choice));
      },
    );
  }

  Widget _multiSummary(AppLocalizations l10n) {
    final ids = _selected.toList();
    final canWrap = _canWrapSelection();
    return Column(
      key: const ValueKey('multi-summary'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(l10n.flow_multiSelectTitle(ids.length))),
            TextButton(
              onPressed: () => setState(_selected.clear),
              child: Text(l10n.flow_multiSelectClear),
            ),
          ],
        ),
        Text(ids.join(' · ')),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: canWrap ? () => _wrapSelection('par') : null,
              child: Text(l10n.flow_wrapPar),
            ),
            OutlinedButton(
              onPressed: canWrap ? () => _wrapSelection('loop') : null,
              child: Text(l10n.flow_wrapLoop),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(l10n.flow_multiSelectHint),
      ],
    );
  }

  bool _canWrapSelection() {
    final rows = [
      for (final id in _selected)
        if (_rowFor(id) case final row?) row,
    ];
    if (rows.length < 2 || rows.length != _selected.length) return false;
    final parent = rows.first.parentId;
    final branch = rows.first.branch;
    if (rows.any((row) => row.parentId != parent || row.branch != branch)) {
      return false;
    }
    final indices = [for (final row in rows) row.index]..sort();
    for (var i = 1; i < indices.length; i++) {
      if (indices[i] != indices[i - 1] + 1) return false;
    }
    return true;
  }

  void _wrapSelection(String kind) {
    final rows = [
      for (final id in _selected)
        if (_rowFor(id) case final row?) row,
    ]..sort((a, b) => a.index.compareTo(b.index));
    if (rows.length < 2) return;
    final wrapperId = _controller.freshId(kind);
    final ops = <Map<String, dynamic>>[
      FlowEditOps.wrap(
        nodeId: rows.first.node.id,
        kind: kind,
        wrapperId: wrapperId,
      ),
      for (final row in rows.skip(1))
        FlowEditOps.move(nodeId: row.node.id, parentId: wrapperId),
    ];
    unawaited(_controller.applyOps(ops));
  }

  void _showReadOnlyNode(FlowNode node) {
    final schema = _controller.schema;
    if (schema == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.92,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            FlowNodeInspector(
              node: node,
              schema: schema,
              readOnly: true,
              yaml: _controller.yaml,
              tree: _controller.tree,
              agentOf: _agentFace,
              changedFields: {
                for (final change in _controller.diff?.of(node.id)?.fields ??
                    const <FlowFieldChange>[])
                  change.field,
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 源码不放进侧栏。人没改过源码时，文本还是打开对话框时的那一版，
  /// 不能在 flush 之后再套回去，否则会把后来的字段改动清掉。
  Future<bool> _applySource(String edited, FlowValidation? checked) async {
    if (!_confirmHeaderLeave()) return false;
    if (!_confirmLeave()) return false;
    final c = _controller;
    final before = c.yaml;
    if (!await c.flush()) return false;
    if (!mounted) return false;
    if (edited != before && edited != c.yaml) {
      final ok = await c.applySource(edited, checked);
      if (!mounted || !ok) return false;
    }
    return true;
  }

  void _openSource() {
    if (!mounted) return;
    _openRight(_RightView.source);
  }

  Widget _rightPanel(AppLocalizations l10n) {
    // 选 Agent、源码、历史都盖在属性上面。把属性拆掉再盖回来时，
    // 检查器是新的一份，刚选的 Agent 还没写进节点，芯片又回到角色。
    return Stack(
      fit: StackFit.expand,
      children: [
        FlowContextPanel(child: _propertiesPane(l10n)),
        if (_rightView != _RightView.properties)
          ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: _rightFill(l10n),
          ),
      ],
    );
  }

  Widget _rightFill(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return switch (_rightView) {
      _RightView.source => _sourcePane(l10n, theme),
      _RightView.history => FlowHistorySheet(
          client: _controller.client,
          peerId: widget.peerId,
          scope: widget.scope,
          name: widget.name,
          latest: _controller.revision,
          onChosen: (choice) => unawaited(_useHistory(choice)),
          onClose: _closeRight,
        ),
      _RightView.agent => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: kToolbarHeight,
              child: Row(
                children: [
                  IconButton(
                    tooltip: l10n.common_back,
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _closeRight,
                  ),
                  Expanded(
                    child: Text(l10n.flow_executorPickAgent,
                        style: theme.textTheme.titleMedium),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: JadeSlipAgentList(
                  agents: _agents,
                  onPick: (pick) {
                    final wait = _agentWait;
                    _agentWait = null;
                    setState(() => _rightView = _RightView.properties);
                    if (wait != null && !wait.isCompleted) {
                      wait.complete(pick.id);
                    }
                  },
                ),
              ),
            ),
          ],
        ),
      _RightView.preview => FlowStartScreen(
          flowName: widget.name,
          yaml: _controller.yaml,
          roles: _previewRoles,
          roleDefaults: _previewDefaults,
          inputSpecs: _previewSpecs,
          dirty: false,
          scope: widget.scope,
          revision: _controller.revision,
          onPickAgent: _pickAgent,
          preview: true,
          embedded: true,
          onDismiss: _closeRight,
        ),
      _RightView.properties => const SizedBox.shrink(),
    };
  }

  Widget _sourcePane(AppLocalizations l10n, ThemeData theme) {
    final c = _controller;
    final editable = canEdit;
    return Padding(
      key: const ValueKey('drawer-source-page'),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.flow_sourceSyncHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('source-close'),
                tooltip: l10n.flow_drawerClose,
                icon: const Icon(Icons.close),
                onPressed: _closeRight,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FlowYamlEditor(
              yaml: c.yaml,
              readOnly: !editable,
              validate: (text) => c.client.validate(widget.peerId, text),
              applyLabel: l10n.flow_sourceApply,
              onApply: (edited, checked) => unawaited(() async {
                final ok = await _applySource(edited, checked);
                if (ok && mounted) _closeRight();
              }()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rehearsalCard(AppLocalizations l10n, ThemeData theme) {
    final rehearsal = _controller.rehearsal;
    final waiting = rehearsal.waiting;
    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.science_outlined),
            title: Text(waiting == null
                ? l10n.flow_rehearsing
                : l10n.flow_rehearseChoose),
            trailing: TextButton(
              onPressed: rehearsal.stop,
              child: Text(l10n.flow_rehearseStop),
            ),
          ),
          // 卡住的地方：选项直接摆出来，选一个就接着走。
          if (waiting case final question?) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                question.prompt,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final option in question.options)
                    FilledButton.tonal(
                      key: ValueKey('rehearse-$option'),
                      onPressed: rehearsal.answering
                          ? null
                          : () => rehearsal.answer(option),
                      child: Text(option),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 底部的"点选 + 说话"条（C.3）：选中的节点 + 一句话，交给群主改。
  Widget? _talkBar(AppLocalizations l10n) {
    if (!canTalk) return null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_reply.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(_reply.toString()),
                ),
              ),
            if (_selected.isNotEmpty)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final id in _selected)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: InputChip(
                          key: ValueKey('sel-$id'),
                          label: Text(id),
                          onDeleted: () => setState(() => _selected.remove(id)),
                        ),
                      ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('talk-input'),
                    controller: _composer,
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: _selected.isEmpty
                          ? l10n.flow_talkHintNoSelection
                          : l10n.flow_talkHint,
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _talking
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : IconButton(
                        key: const ValueKey('talk-send'),
                        tooltip: l10n.flow_talkSend,
                        icon: const Icon(Icons.send),
                        onPressed: _talk,
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
