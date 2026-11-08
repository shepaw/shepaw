import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/flow/flow_draft_store.dart';
import '../controllers/flow/flow_editor_controller.dart';
import '../l10n/app_localizations.dart';
import '../peer/models/flow_models.dart';
import '../peer/services/hub_flow.dart';
import '../utils/layout_utils.dart';
import '../widgets/flow/flow_steps_pane.dart';
import 'flow_design_screen.dart';

/// 一个流程的编辑页。
///
/// 点进流程就到这里：桌面直接编辑，手机只读看步骤。不再分概览 / 编辑 / 运行。
/// 运行记录留在流程库自己的「运行记录」里。
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

  @override
  State<FlowDetailScreen> createState() => _FlowDetailScreenState();
}

class _FlowDetailScreenState extends State<FlowDetailScreen> {
  Widget? _editPane;
  FlowEditorController? _editor;
  FlowDraft? _draft;
  final ValueNotifier<int> _restoreRequests = ValueNotifier<int>(0);

  bool get _desktop => LayoutUtils.isDesktopLayout(context);

  @override
  void initState() {
    super.initState();
    widget.draftStore.drafts.addListener(_onDraftStoreChanged);
    unawaited(_loadDraft());
  }

  @override
  void didUpdateWidget(covariant FlowDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flow.name != widget.flow.name ||
        oldWidget.peerId != widget.peerId ||
        oldWidget.scope != widget.scope) {
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

  Widget _buildEditPane() {
    return FlowDesignScreen(
      peerId: widget.peerId,
      name: widget.flow.name,
      scope: widget.scope,
      client: widget.client,
      draftStore: widget.draftStore,
      embedded: true,
      restoreRequests: _restoreRequests,
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
              title: Text(widget.flow.name),
              automaticallyImplyLeading: false,
            )
          : null,
      body: Column(
        children: [
          if (_draft != null) _draftBanner(l10n),
          Expanded(child: _desktop ? _editorPane() : _stepsPane()),
        ],
      ),
    );
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
