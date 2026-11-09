import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/flow/flow_draft_store.dart';
import '../controllers/flow/flow_editor_controller.dart';
import '../controllers/flow/flow_host_caps.dart';
import '../l10n/app_localizations.dart';
import '../peer/models/flow_models.dart';
import '../peer/services/hub_flow.dart';
import '../utils/layout_utils.dart';
import '../widgets/flow/flow_steps_pane.dart';
import 'flow_design_screen.dart';

/// 一个流程的编辑页。
///
/// 点进流程就到这里：主机支持编辑就直接改（手机也一样，只是换成整页表单）；
/// 只有连到不支持编辑操作的旧主机时，手机才退回只读步骤页 + 点选说话。
/// 执行历史从列表或这里的菜单打开，不在编辑页里再分一栏。
///
/// 编辑页只创建一次，切走再回来不销毁撤销栈 / 草稿。
class FlowDetailScreen extends StatefulWidget {
  const FlowDetailScreen({
    super.key,
    required this.peerId,
    required this.flow,
    required this.client,
    required this.draftStore,
    this.scope = '',
    this.showHeader = false,
    this.onDirtyChanged,
    this.onControllerReady,
    this.pageOpen,
    this.onOpenExecutions,
  });

  final String peerId;
  final FlowSummary flow;
  final HubFlow client;
  final FlowDraftStore draftStore;
  final String scope;

  /// 宽屏时自己画一条标题（外层工作台嵌在右栏，没有 AppBar）。
  final bool showHeader;

  final ValueChanged<bool>? onDirtyChanged;
  final ValueChanged<FlowEditorController?>? onControllerReady;

  /// 工作台用来判断手机整页属性有没有开（系统返回键的层级）。
  final ValueNotifier<bool>? pageOpen;

  final VoidCallback? onOpenExecutions;

  @override
  State<FlowDetailScreen> createState() => _FlowDetailScreenState();
}

class _FlowDetailScreenState extends State<FlowDetailScreen> {
  Widget? _editPane;
  FlowEditorController? _editor;
  FlowDraft? _draft;
  final ValueNotifier<int> _restoreRequests = ValueNotifier<int>(0);
  VoidCallback? _openSettings;

  /// 手机上用哪套界面取决于主机能力（不是设备）：null = 还在问主机。
  bool? _hostEditable;
  int _capsGen = 0;
  bool _capsRequested = false;

  bool get _desktop => LayoutUtils.isDesktopLayout(context);
  bool get _editableHere => _desktop || _hostEditable == true;

  @override
  void initState() {
    super.initState();
    widget.draftStore.drafts.addListener(_onDraftStoreChanged);
    unawaited(_loadDraft());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery 在这里才稳定：窗口从宽变窄时也要补问一次主机能力。
    if (!_desktop && !_capsRequested) {
      _capsRequested = true;
      unawaited(_loadCaps());
    }
  }

  @override
  void didUpdateWidget(covariant FlowDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flow.name != widget.flow.name ||
        oldWidget.peerId != widget.peerId ||
        oldWidget.scope != widget.scope) {
      _editPane = null;
      _editor = null;
      _hostEditable = null;
      _capsRequested = !_desktop;
      unawaited(_loadDraft());
      if (!_desktop) unawaited(_loadCaps());
    }
  }

  /// 手机上要选「编辑页」还是「只读步骤页」，只看主机给的 ops。
  /// 桌面不受影响（一直进编辑页，由它自己显示只读原因）。
  Future<void> _loadCaps() async {
    final gen = ++_capsGen;
    final schema = await widget.client.schema(widget.peerId);
    if (!mounted || gen != _capsGen) return;
    setState(() => _hostEditable =
        schema == null ? null : FlowHostCaps.of(schema, const []).canEdit);
    if (schema == null) {
      // 一次超时不是「主机不支持编辑」的结论：别把详情页永久钉在只读
      // 步骤页上，等下一次依赖变化 / 重新进入时再问一次。
      _capsRequested = false;
    }
  }

  void _onDraftStoreChanged() => unawaited(_loadDraft());

  @override
  void dispose() {
    widget.draftStore.drafts.removeListener(_onDraftStoreChanged);
    _restoreRequests.dispose();
    super.dispose();
  }

  Future<void> _loadDraft() async {
    final draft = await widget.draftStore.load(
      peerId: widget.peerId,
      scope: widget.scope,
      name: widget.flow.name,
    );
    if (!mounted) return;
    final usable = draft?.yaml.isNotEmpty == true ? draft : null;
    if (_draft?.yaml == usable?.yaml) return;
    setState(() => _draft = usable);
  }

  Widget _buildEditPane() {
    return FlowDesignScreen(
      peerId: widget.peerId,
      name: widget.flow.name,
      scope: widget.scope,
      client: widget.client,
      draftStore: widget.draftStore,
      embedded: true,
      chromeInParent: widget.showHeader,
      onBindSettings: (open) => _openSettings = open,
      restoreRequests: _restoreRequests,
      pageOpen: widget.pageOpen,
      onOpenExecutions: widget.onOpenExecutions,
      onDirtyChanged: widget.onDirtyChanged,
      onControllerReady: (controller) {
        _editor = controller;
        widget.onControllerReady?.call(controller);
      },
    );
  }

  void _restoreDraft() {
    _restoreRequests.value++;
  }

  Future<void> _discardDraft() async {
    await widget.draftStore.clear(
      peerId: widget.peerId,
      scope: widget.scope,
      name: widget.flow.name,
    );
    _editor?.discardDraft();
    if (mounted) setState(() => _draft = null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: widget.showHeader
          ? AppBar(
              automaticallyImplyLeading: false,
              title: _settingsTitle(l10n),
              actions: [
                if (widget.onOpenExecutions != null)
                  TextButton.icon(
                    key: const ValueKey('executions-open'),
                    onPressed: widget.onOpenExecutions,
                    icon: const Icon(Icons.history, size: 18),
                    label: Text(l10n.flow_listExecutions),
                  ),
              ],
            )
          : null,
      body: Column(
        children: [
          if (_draft != null) _draftBanner(l10n),
          Expanded(child: _mainPane()),
        ],
      ),
    );
  }

  Widget _settingsTitle(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: l10n.flow_headerOpen,
      child: InkWell(
        key: const ValueKey('flow-title'),
        onTap: () => _openSettings?.call(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.flow.name,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.underline,
                decorationColor: scheme.primary,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.tune, size: 18, color: scheme.primary),
          ],
        ),
      ),
    );
  }

  Widget _mainPane() {
    if (_desktop) return _editorPane();
    // 能力探测还没回来（或这一问超时了）也直接进编辑页：它自己有 loading /
    // 失败态和只读降级，不必再让手机干等一次网络往返。只有明确拿到
    // 「不支持编辑 ops」才退回只读步骤页。
    if (_hostEditable == false) return _stepsPane();
    return _editorPane();
  }

  Widget _editorPane() => _editPane ??= _buildEditPane();

  Widget _stepsPane() {
    return FlowStepsPane(
      client: widget.client,
      peerId: widget.peerId,
      name: widget.flow.name,
      scope: widget.scope,
      draftYaml: _draft?.yaml,
    );
  }

  Widget _draftBanner(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('draft-banner'),
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            const Icon(Icons.history, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(l10n.flow_draftBannerTitle)),
            if (_editableHere)
              TextButton(
                key: const ValueKey('draft-restore'),
                onPressed: _restoreDraft,
                child: Text(l10n.flow_draftBannerRestore),
              )
            else
              Text(
                l10n.flow_draftBannerReadOnly,
                style: theme.textTheme.bodySmall,
              ),
            TextButton(
              key: const ValueKey('draft-discard'),
              onPressed: () => unawaited(_discardDraft()),
              child: Text(l10n.flow_draftBannerDiscard),
            ),
          ],
        ),
      ),
    );
  }
}
