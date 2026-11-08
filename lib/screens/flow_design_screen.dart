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
import '../screens/jade_slip_agent_picker.dart';
import '../services/local_database_service.dart';
import '../services/local_user_identity.dart';
import '../utils/layout_utils.dart';
import '../widgets/discard_changes_scope.dart';
import '../widgets/flow/flow_context_panel.dart';
import '../widgets/flow/flow_diagnostics_panel.dart';
import '../widgets/flow/flow_header_form.dart';
import '../widgets/flow/flow_history_sheet.dart';
import '../widgets/flow/flow_node_inspector.dart';
import '../widgets/flow/flow_node_tree.dart';
import '../widgets/flow/flow_outline_menu.dart';
import '../widgets/flow/flow_outline_tree.dart';
import '../widgets/flow/flow_yaml_editor.dart';

/// 流程设计视图（方案 C.3–C.5）：节点树 + 检查器改字段 + 与上一版的差异 + 演练。
///
/// App 不解析 YAML：每次改动都发给 Hub（`flow_edit_req`），用回来的节点树重画；
/// 不合法的地方在诊断里。保存才写进流程库成为新的 revision。
///
/// 草稿状态在 [FlowEditorController] 里，这一层只管画布、检查器弹出、源码条
/// 和「点选 + 说话」。
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
    this.initialDrawerTab,
    this.restoreRequests,
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

  /// 嵌在工作台详情区里：不画自己的 AppBar（外层详情页已经有 Tab 栏）。
  final bool embedded;

  /// 从概览页「演练」进来时，侧栏抽屉直接落在演练页签。
  final String? initialDrawerTab;

  /// 概览页草稿横幅点「恢复」时 +1；设计页等控制器载入完草稿再恢复。
  final ValueNotifier<int>? restoreRequests;

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

  /// 右侧上下文面板。默认展开，页签是属性 / 问题 / 演练 / 源码。
  bool _panelOpen = true;
  String _panelTab = 'properties';
  double _panelWidth = 380;
  bool _overlay = false;
  bool _leaveArmed = false;
  bool _inspectorInvalid = false;
  int _focusNonce = 0;
  int _discardNonce = 0;
  String? _flashField;
  final FocusNode _outlineFocus = FocusNode();
  static const _panelTabs = ['properties', 'problems', 'rehearsal', 'source'];

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

  /// 编排只在桌面开（手机只读，但保留「点选 + 说话」），并且主机得支持这些操作。
  bool get canEdit =>
      LayoutUtils.isDesktopLayout(context) && _controller.caps.canEdit;

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
    if (_panelTabs.contains(widget.initialDrawerTab)) {
      _panelTab = widget.initialDrawerTab!;
      _panelOpen = true;
    }
    _loadPanelWidth();
    widget.restoreRequests?.addListener(_onRestoreRequest);
    _startController();
    unawaited(_loadFlowRefs());
  }

  static const _panelWidthKey = 'flow_context_panel_width';

  Future<void> _loadPanelWidth() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final width = prefs.getDouble(_panelWidthKey);
      if (!mounted || width == null) return;
      setState(() => _panelWidth = width.clamp(320, 560));
    } catch (_) {
      // 测试里没初始化偏好时用默认宽度。
    }
  }

  void _rememberPanelWidth(double width) {
    final next = width.clamp(320, 560).toDouble();
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
            key: const ValueKey('conflict-diff'),
            onPressed: () => Navigator.pop(dialog, 'diff'),
            child: Text(l10n.flow_diffToggle),
          ),
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
      case 'diff':
        if (!_controller.showDiff) await _controller.toggleDiff();
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
          _panelTab = 'properties';
          _panelOpen = true;
          _leaveArmed = false;
        });
        _flashTimer?.cancel();
        _flashTimer = Timer(const Duration(milliseconds: 1500), () {
          if (mounted) setState(() => _flashId = null);
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
    unawaited(_controller.applyOps([
      FlowOutlineOps.insertAfter(row, _newStep()),
    ]));
  }

  void _move(FlowOutlineRow row, {required bool up}) {
    unawaited(_controller.applyOps([
      up ? FlowOutlineOps.moveUp(row) : FlowOutlineOps.moveDown(row),
    ]));
  }

  /// 拖放落点：发一个 move（撤销走编辑器快照），落下后选中并滚到被拖节点。
  void _onDrop(String dragId, FlowDropTarget target) {
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
    unawaited(_rowMenu(row));
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
    final choice = await showFlowHistorySheet(
      context,
      client: _controller.client,
      peerId: widget.peerId,
      scope: widget.scope,
      name: widget.name,
      latest: _controller.revision,
    );
    if (choice == null || !mounted) return;
    final checked =
        await _controller.client.validate(widget.peerId, choice.yaml);
    if (!mounted) return;
    await _controller.applySource(choice.yaml, checked);
  }

  Future<void> _rowMenu(FlowOutlineRow row, {Offset? position}) async {
    final choice = await showFlowOutlineMenu(
      context,
      row: row,
      canRetype: _controller.caps.canRetype,
      position: position,
    );
    if (choice == null || !mounted) return;
    await _applyMenuChoice(row, choice);
  }

  Future<void> _applyMenuChoice(
    FlowOutlineRow row,
    FlowOutlineMenuChoice choice,
  ) async {
    final step = _newStep;
    switch (choice.action) {
      case FlowOutlineMenuAction.insertAfter:
        _addAfter(row);
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
        await _delete(row);
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
    }
  }

  Future<void> _delete(FlowOutlineRow row) async {
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
    if (node.id != _selectedId && !_confirmLeave()) return;
    setState(() {
      _selectedId = node.id;
      _panelTab = 'properties';
      _leaveArmed = false;
      if (_overlay) _panelOpen = true;
    });
    _outlineFocus.requestFocus();
  }

  void _showFlowSettings() {
    if (!_confirmLeave()) return;
    setState(() {
      _selectedId = null;
      _panelTab = 'properties';
      _panelOpen = true;
      _leaveArmed = false;
    });
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

  // ── 点选 + 说话 ───────────────────────────────────────────────────────────

  void _toggleSelected(FlowNode node) {
    if (_controller.busy) return;
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
  Future<String?> _pickAgent() async {
    if (_agents.isEmpty) {
      final epoch = _hostEpoch;
      final peerId = widget.peerId;
      final all = await LocalDatabaseService().getAllRemoteAgents();
      if (!mounted || epoch != _hostEpoch || peerId != widget.peerId) {
        return null;
      }
      setState(() => _agents =
          all.where((a) => a.isPeerAgent && a.sourcePeerId == peerId).toList());
    }
    final l10n = AppLocalizations.of(context);
    final picked = await showJadeSlipAgentPicker(
      context,
      agents: _agents,
      title: l10n.flow_executorPickAgent,
    );
    if (picked == null) return null;
    final agent = _agents.where((a) => a.id == picked.id).firstOrNull;
    // 选择弹层里还有惜宝那条（不在 _agents 里）：原样返回，沿用旧行为。
    return agent == null ? picked.id : hubAgentIdOf(agent);
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
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        return Scaffold(
          // 嵌在详情页里时，Tab 栏在上面；这里不再叠第二条 AppBar。
          appBar: widget.embedded
              ? null
              : AppBar(
                  title: Text(l10n.flow_designTitle(widget.name)),
                  automaticallyImplyLeading: false,
                ),
          body: Column(
            children: [
              _toolbar(context, l10n, c),
              if (c.rehearsal.active) _rehearsalBanner(l10n),
              Expanded(child: _body(l10n)),
              if (_talkBar(l10n) case final bar?) bar,
            ],
          ),
        );
      },
    );
  }

  /// 工具条分层：左边流程名 + 保存状态文字，主区只有 保存 / 演练 / 撤销 /
  /// 重做，低频操作全收进 `⋯`。窄宽度进一步收成 保存 + `⋯`。
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
        final compact = constraints.maxWidth < 600;
        final statusText = c.saving
        ? l10n.flow_toolbarSaving
        : c.errorCount > 0
            ? l10n.flow_toolbarProblems(c.errorCount)
            : c.dirty
                ? l10n.flow_toolbarUnsaved
                : l10n.flow_toolbarSaved(c.revision);
    return Material(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.name,
                      style: theme.textTheme.labelLarge,
                      overflow: TextOverflow.ellipsis),
                  Text(
                    statusText,
                    key: const ValueKey('save-status'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: c.dirty || c.errorCount > 0
                          ? scheme.error
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  // 独立打开设计页（不在工作台里）时保留一个纯版本号标签：
                  // 保存状态文字是「已保存第 N 版」，这个短标签便于核对版本。
                  if (!widget.embedded && c.revision > 0)
                    Text(l10n.flow_revisionLabel(c.revision),
                        key: const ValueKey('revision-label'),
                        style: theme.textTheme.labelSmall),
                ],
              ),
            ),
            if (canEdit)
              FilledButton.icon(
                key: const ValueKey('save-button'),
                onPressed: c.loading || c.busy || !c.dirty
                    ? null
                    : () => _doSave(c),
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
            if (canEdit)
              IconButton(
                key: const ValueKey('diff-toggle'),
                tooltip: _diffTooltip(l10n, c),
                icon: Icon(
                  Icons.difference_outlined,
                  color: c.showDiff ? scheme.primary : null,
                ),
                onPressed: c.loading ? null : () => unawaited(c.toggleDiff()),
              ),
            if (canEdit)
              compact
                  ? IconButton(
                      key: const ValueKey('header-open'),
                      tooltip: l10n.flow_headerOpen,
                      icon: const Icon(Icons.tune),
                      onPressed: _showFlowSettings,
                    )
                  : TextButton.icon(
                      key: const ValueKey('header-open'),
                      onPressed: _showFlowSettings,
                      icon: const Icon(Icons.tune, size: 18),
                      label: Text(l10n.flow_headerOpen),
                    ),
            if (canEdit) _moreMenu(l10n, c),
          ],
        ),
      ),
      );
    },
  );
  }

  Widget _moreMenu(AppLocalizations l10n, FlowEditorController c) {
    return PopupMenuButton<String>(
      key: const ValueKey('design-more'),
      tooltip: l10n.flow_toolbarMore,
      onSelected: (choice) => _onMenuChoice(choice, c),
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          key: const ValueKey('history-open'),
          value: 'history',
          enabled: canEdit && c.revision > 1,
          child: Text(l10n.flow_historyOpen),
        ),
        PopupMenuItem<String>(
          // 旧的「源码条」入口 key 保持不变，现在打开侧栏的源码页签。
          key: const ValueKey('yaml-bar'),
          value: 'source',
          child: Text(l10n.flow_source),
        ),
        PopupMenuItem<String>(
          key: const ValueKey('menu-problems'),
          value: 'problems',
          child: Text(l10n.flow_drawerProblems),
        ),
        PopupMenuItem<String>(
          key: const ValueKey('menu-rehearsal'),
          value: 'rehearsal',
          child: Text(l10n.flow_drawerRehearsal),
        ),
      ],
    );
  }

  void _onMenuChoice(String choice, FlowEditorController c) {
    switch (choice) {
      case 'history':
        unawaited(_openHistory());
      case 'source':
        _openPanel('source');
      case 'problems':
        _openPanel('problems');
      case 'rehearsal':
        _openPanel('rehearsal');
    }
  }

  String _diffTooltip(AppLocalizations l10n, FlowEditorController c) {
    final diff = c.diff;
    if (!c.showDiff || diff == null) return l10n.flow_diffToggle;
    final count = diff.nodes.length + diff.header.length;
    if (count == 0) return l10n.flow_diffNone;
    return l10n.flow_diffSummary(count);
  }

  void _openPanel(String tab) {
    if (!mounted) return;
    setState(() {
      _panelOpen = true;
      _panelTab = tab;
    });
  }

  void _doSave(FlowEditorController c) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (c.errorCount > 0) _openPanel('problems');
    unawaited(c.save());
  }

  void _startRehearsal(FlowEditorController c) {
    // 演练的图标 / 文案与「开始运行」显式区分；演练期间顶部一直挂着提示条。
    _openPanel('rehearsal');
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
    // 节点树独占首屏：问题 / 对比 / 演练 / 源码都搬进右侧抽屉，不再作为
    // 卡片插在树上面把它挤下去。抽屉开合只改 Row 的分割，树的滚动位置由
    // 同一个 ListView 自己保留。
    final treePane = ListView(
      key: const ValueKey('flow-node-tree'),
      padding: const EdgeInsets.all(12),
      children: [
        // 桌面但主机缺操作：明确说清为什么只读，别让人以为按钮坏了。
        if (!canEdit && LayoutUtils.isDesktopLayout(context))
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
              dragEnabled: !c.busy,
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
                        FlowChange.added => (l10n.flow_diffAdded, Colors.green),
                        FlowChange.changed => (
                            l10n.flow_diffChanged,
                            Colors.amber
                          ),
                        _ => null,
                      };
                    },
              onTapRow: (row) => _selectNode(row.node),
              onSecondaryTapRow: (row, position) =>
                  unawaited(_rowMenu(row, position: position)),
              onToggleCollapse: _toggleCollapse,
              onAddAfter: _addAfter,
              onMoveUp: (row) => _move(row, up: true),
              onMoveDown: (row) => _move(row, up: false),
              onDelete: _delete,
              onMenu: _rowMenu,
              onLongPressRow:
                  canTalk ? (row) => _toggleSelected(row.node) : null,
            ),
          )
        else
          FlowNodeTree(
            nodes: rehearsal.view(c.tree),
            onTapNode: canEdit ? _selectNode : _showReadOnlyNode,
            onLongPressNode: canTalk ? _toggleSelected : null,
            selectedIds: _selected,
            badgeFor: diff == null
                ? null
                : (node) {
                    final change = diff.of(node.id);
                    return switch (change?.change) {
                      FlowChange.added => (l10n.flow_diffAdded, Colors.green),
                      FlowChange.changed => (
                          l10n.flow_diffChanged,
                          Colors.amber
                        ),
                      _ => null,
                    };
                  },
          ),
        if (diff != null && diff.removed.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              l10n.flow_diffRemoved(diff.removed.map((n) => n.id).join(', ')),
              style: theme.textTheme.bodySmall?.copyWith(
                decoration: TextDecoration.lineThrough,
                color: Colors.grey,
              ),
            ),
          ),
        if (diff != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              diff.isEmpty
                  ? l10n.flow_diffNone
                  : l10n.flow_diffSummary(
                      diff.nodes.length + diff.header.length),
              key: const ValueKey('diff-summary'),
              style: theme.textTheme.labelMedium,
            ),
          ),
      ],
    );
    if (_selectedId != null && _nodeById(_selectedId!) == null) {
      final stale = _selectedId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedId == stale) {
          setState(() => _selectedId = null);
        }
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
        final showPanel = canEdit && _panelOpen;
        if (_overlay != !wide) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _overlay == wide) setState(() => _overlay = !wide);
          });
        }
        final panel = showPanel
            ? FlowContextPanel(
                tab: _panelTab,
                onTab: _openPanel,
                onClose: () => setState(() => _panelOpen = false),
                problemCount: c.errorCount,
                onDragWidth: wide
                    ? (delta) => _rememberPanelWidth(_panelWidth + delta)
                    : null,
                properties: _propertiesPane(l10n),
                problems: _problemsPage(l10n),
                rehearsal: _rehearsalPage(l10n, theme),
                source: _sourcePage(l10n, theme),
              )
            : null;
        final treeStack = Stack(
          children: [
            treePane,
            if (canEdit && !showPanel)
              Positioned.directional(
                textDirection: Directionality.of(context),
                end: 8,
                top: 8,
                child: IconButton(
                  key: const ValueKey('drawer-open'),
                  tooltip: l10n.flow_drawerOpen,
                  icon: const Icon(Icons.view_sidebar_outlined),
                  onPressed: () => _openPanel('properties'),
                ),
              ),
          ],
        );
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: treeStack),
              if (panel != null) SizedBox(width: _panelWidth, child: panel),
            ],
          );
        }
        final overlayWidth = width < 600 ? width : (width * 0.85).clamp(0, 380).toDouble();
        return Stack(
          children: [
            Positioned.fill(child: treeStack),
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
    if (_selected.length >= 2) return _multiSummary(l10n);
    final selected = _selectedId == null ? null : _nodeById(_selectedId!);
    final schema = c.schema;
    if (selected == null || schema == null) {
      return FlowHeaderForm(
        controller: c,
        readOnly: !c.caps.canEditHeader || c.rehearsal.active,
        onPickAgent: _pickAgent,
        tree: c.tree,
      );
    }
    final problems = [
      for (final d in c.diagnostics)
        if (resolveDiagnostic(d, c.tree) case NodeTarget(:final nodeId))
          if (nodeId == selected.id) d.message,
    ];
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
      peerId: widget.peerId,
      tree: c.tree,
      yaml: c.yaml,
      flowRefs: _flowRefs,
      problems: problems,
      rejections: {
        for (final spec in FlowFieldCatalog.specsFor(selected.kind, schema))
          if (c.rejection(selected.id, spec.path) case final reason?)
            spec.path: reason,
      },
      flashField: _flashField,
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
            ),
          ],
        ),
      ),
    );
  }

  Widget _problemsPage(AppLocalizations l10n) {
    return ListView(
      key: const ValueKey('drawer-problems-page'),
      padding: const EdgeInsets.all(12),
      children: [
        FlowDiagnosticsPanel(
          diagnostics: _controller.diagnostics,
          tree: _controller.tree,
          onLocate: _locate,
        ),
      ],
    );
  }

  Widget _rehearsalPage(AppLocalizations l10n, ThemeData theme) {
    final c = _controller;
    return ListView(
      key: const ValueKey('drawer-rehearsal-page'),
      padding: const EdgeInsets.all(12),
      children: [
        Text(l10n.flow_rehearseHint, style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        if (!c.rehearsal.active)
          OutlinedButton.icon(
            key: const ValueKey('rehearse-start'),
            onPressed: c.loading || c.busy
                ? null
                : () => _startRehearsal(c),
            icon: const Icon(Icons.science_outlined, size: 18),
            label: Text(l10n.flow_rehearseStart),
          )
        else ...[
          _rehearsalCard(l10n, theme),
          const SizedBox(height: 8),
          // 演练走过的时间线：走到哪一步一眼看得出，不用回到节点树数。
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final step in c.rehearsal.rehearsal?.steps ?? const <String>[])
                Chip(
                  key: ValueKey('rehearse-step-$step'),
                  label: Text(step, style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _sourcePage(AppLocalizations l10n, ThemeData theme) {
    final c = _controller;
    final editable = canEdit && MediaQuery.of(context).size.width >= 900;
    return Column(
      key: const ValueKey('drawer-source-page'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            l10n.flow_sourceSyncHint,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: FlowYamlEditor(
              yaml: c.yaml,
              readOnly: !editable,
              validate: (text) => c.client.validate(widget.peerId, text),
              applyLabel: l10n.flow_sourceApply,
              onApply: (edited, checked) {
                setState(() => _panelOpen = false);
                unawaited(c.applySource(edited, checked));
              },
            ),
          ),
        ),
      ],
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
                          onDeleted: () =>
                              setState(() => _selected.remove(id)),
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
