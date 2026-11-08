import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../controllers/flow/flow_draft_store.dart';
import '../controllers/flow/flow_editor_controller.dart';
import '../l10n/app_localizations.dart';
import '../peer/models/flow_models.dart';
import '../peer/services/hub_flow.dart';
import '../utils/layout_utils.dart';
import '../widgets/flow/flow_overview_pane.dart';
import '../widgets/flow/flow_runs_pane.dart';
import '../widgets/flow/flow_steps_pane.dart';
import 'flow_design_screen.dart';

/// 一个流程的容器：概览 / 编辑 / 运行三个明确的去处。
///
/// - 默认落在**概览**：说明、版本、最近运行、开始运行；
/// - **编辑**只在桌面有（手机只读，编辑 Tab 根本不画，也不留灰掉的按钮）；
/// - **运行**是这个流程自己的历史，不再把全库运行平铺在列表栏里。
///
/// 用 [IndexedStack] + 缓存的编辑页，切 Tab 不销毁编辑器的撤销栈 / 草稿；
/// 但编辑页只在第一次点到「编辑」时才创建，概览页不会白白发一轮编辑请求。
class FlowDetailScreen extends StatefulWidget {
  const FlowDetailScreen({
    super.key,
    required this.peerId,
    required this.flow,
    required this.client,
    required this.draftStore,
    required this.onStart,
    required this.onOpenRun,
    this.scope = '',
    this.showHeader = false,
    this.onDirtyChanged,
    this.onControllerReady,
    this.initialTab = 0,
  });

  final String peerId;
  final FlowSummary flow;
  final HubFlow client;
  final FlowDraftStore draftStore;
  final String scope;

  /// 宽屏时自己画一条带 Tab 的标题栏（外层工作台嵌在右栏，没有 AppBar）。
  final bool showHeader;

  final VoidCallback onStart;
  final void Function(String runId, String title) onOpenRun;
  final ValueChanged<bool>? onDirtyChanged;
  final ValueChanged<FlowEditorController?>? onControllerReady;

  /// 打开时落在哪个 Tab（0 概览 / 1 编辑 / 2 运行；窄屏会夹到合法范围）。
  final int initialTab;

  @override
  State<FlowDetailScreen> createState() => _FlowDetailScreenState();
}

class _FlowDetailScreenState extends State<FlowDetailScreen> {
  int _index = 0;
  Widget? _editPane;
  String? _drawerIntent;
  FlowEditorController? _editor;
  FlowDraft? _draft;
  final ValueNotifier<int> _restoreRequests = ValueNotifier<int>(0);

  bool get _desktop => LayoutUtils.isDesktopLayout(context);
  int get _runsIndex => 2;

  @override
  void initState() {
    super.initState();
    _index = widget.initialTab.clamp(0, 2);
    widget.draftStore.drafts.addListener(_onDraftStoreChanged);
    unawaited(_loadDraft());
  }

  @override
  void didUpdateWidget(covariant FlowDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flow.name != widget.flow.name ||
        oldWidget.peerId != widget.peerId ||
        oldWidget.scope != widget.scope) {
      _index = 0;
      _editPane = null;
      _editor = null;
      unawaited(_loadDraft());
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

  void _goTo(int index) {
    final target = index.clamp(0, _runsIndex);
    if (target == 1 && _desktop) {
      _editPane ??= _buildEditPane();
    }
    setState(() => _index = target);
    if (target == 0) unawaited(_loadDraft());
  }

  Widget _buildEditPane() {
    // 待办意图只消费一次：换流程后重开的编辑页不该还停在演练页签。
    final intent = _drawerIntent;
    _drawerIntent = null;
    return FlowDesignScreen(
        peerId: widget.peerId,
        name: widget.flow.name,
        scope: widget.scope,
        client: widget.client,
        draftStore: widget.draftStore,
        embedded: true,
        initialDrawerTab: intent,
        restoreRequests: _restoreRequests,
        onDirtyChanged: widget.onDirtyChanged,
        onControllerReady: (controller) {
          _editor = controller;
          widget.onControllerReady?.call(controller);
        },
      );
  }

  void _rehearse() {
    if (!_desktop) return;
    setState(() => _drawerIntent = 'rehearsal');
    _editPane = _buildEditPane();
    setState(() => _index = 1);
  }

  void _restoreDraft() {
    _restoreRequests.value++;
    if (_desktop) _goTo(1);
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
    final tabs = _tabsStrip(l10n);
    return Scaffold(
      appBar: widget.showHeader
          ? AppBar(
              title: Text(widget.flow.name),
              automaticallyImplyLeading: false,
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: tabs,
              ),
            )
          : null,
      body: Column(
        children: [
          if (!widget.showHeader) tabs,
          Expanded(
            child: IndexedStack(
              index: _index.clamp(0, _runsIndex),
              children: _panes(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabsStrip(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final entries = <(String, IconData, String)>[
      ('detail-tab-overview', Icons.info_outline, l10n.flow_tabOverview),
      if (_desktop)
        ('detail-tab-edit', Icons.edit_outlined, l10n.flow_tabEdit),
      if (!_desktop)
        ('detail-tab-steps', Icons.account_tree_outlined, l10n.flow_tabSteps),
      ('detail-tab-runs', Icons.playlist_play, l10n.flow_tabRuns),
    ];
    return Material(
      color: widget.showHeader ? null : scheme.surface,
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          for (var i = 0; i < entries.length; i++)
            Expanded(
              child: InkWell(
                key: ValueKey(entries[i].$1),
                onTap: () => _goTo(i),
                child: Container(
                  height: 46,
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        width: _index == i ? 2 : 0,
                        color: _index == i ? scheme.primary : Colors.transparent,
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        entries[i].$2,
                        size: 16,
                        color: _index == i
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        entries[i].$3,
                        style: TextStyle(
                          color: _index == i
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                          fontWeight:
                              _index == i ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _panes() {
    final overview = FlowOverviewPane(
      flow: widget.flow,
      client: widget.client,
      peerId: widget.peerId,
      scope: widget.scope,
      onStart: widget.onStart,
      onRehearse: _desktop ? _rehearse : null,
      onOpenRun: widget.onOpenRun,
      draftBanner:
          _draft == null ? null : _draftBanner(AppLocalizations.of(context)),
    );
    final runs = FlowRunsPane(
      client: widget.client,
      peerId: widget.peerId,
      scope: widget.scope,
      name: widget.flow.name,
      onOpenRun: widget.onOpenRun,
    );
    final steps = FlowStepsPane(
      client: widget.client,
      peerId: widget.peerId,
      name: widget.flow.name,
      scope: widget.scope,
      draftBanner:
          _draft == null ? null : _draftBanner(AppLocalizations.of(context)),
    );
    return _desktop
        ? [overview, _editPane ?? const SizedBox.shrink(), runs]
        : [overview, steps, runs];
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
            if (_desktop)
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
