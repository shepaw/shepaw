import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/flow/flow_edit_ops.dart';
import '../controllers/flow/flow_editor_controller.dart';
import '../controllers/flow/flow_executor.dart';
import '../controllers/flow/flow_editor_notice.dart';
import '../controllers/flow/flow_outline.dart';
import '../l10n/app_localizations.dart';
import '../peer/models/flow_models.dart';
import '../peer/pouch_turn_relay.dart';
import '../peer/services/hub_flow.dart';
import '../models/remote_agent.dart';
import '../screens/jade_slip_agent_picker.dart';
import '../services/local_database_service.dart';
import '../services/local_user_identity.dart';
import '../utils/layout_utils.dart';
import '../widgets/discard_changes_scope.dart';
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
  });

  final String peerId;
  final String name;
  final String scope;
  final HubFlow? client;

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
  late final FlowEditorController _controller;
  bool _showYaml = false;

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
    _controller = FlowEditorController(
      peerId: widget.peerId,
      name: widget.name,
      scope: widget.scope,
      client: widget.client,
      stepInterval: widget.stepInterval,
    );
    _controller.onNotice = _notice;
    unawaited(_controller.load());
  }

  @override
  void dispose() {
    _composer.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 控制器只说"发生了什么"，文案在这配。
  void _notice(FlowEditorNotice notice) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final text = switch (notice.kind) {
      FlowEditorNoticeKind.hostNoReply => l10n.flow_hostNoReply,
      FlowEditorNoticeKind.editRejected =>
        notice.raw ?? l10n.flow_editFailed,
      FlowEditorNoticeKind.saveRejected =>
        notice.raw ?? l10n.flow_saveFailed,
      FlowEditorNoticeKind.hasProblems => l10n.flow_hasProblems(notice.count),
      FlowEditorNoticeKind.saved => l10n.flow_saved(notice.count),
      FlowEditorNoticeKind.sourceInvalid =>
        l10n.flow_hasProblems(notice.count),
    };
    _snack(text);
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  // ── 检查器 ────────────────────────────────────────────────────────────────

  // ── 大纲 ──────────────────────────────────────────────────────────────────

  List<FlowOutlineRow> _rows() =>
      buildFlowOutline(_controller.tree, collapsed: _collapsed);

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
      final at = d.at;
      if (at.isEmpty) continue;
      final id = at.split('/').last;
      out[id] = (out[id] ?? 0) + 1;
    }
    return out;
  }

  void _toggleCollapse(FlowOutlineRow row) {
    setState(() {
      if (!_collapsed.add(row.node.id)) _collapsed.remove(row.node.id);
    });
  }

  void _addAfter(FlowOutlineRow row) {
    unawaited(_controller.applyOps([
      FlowOutlineOps.insertAfter(
        row,
        FlowStepDefaults.step(
          _controller.freshId('step'),
          'task',
          prompt: AppLocalizations.of(context).flow_newStepPrompt,
        ),
      ),
    ]));
  }

  void _move(FlowOutlineRow row, {required bool up}) {
    unawaited(_controller.applyOps([
      up ? FlowOutlineOps.moveUp(row) : FlowOutlineOps.moveDown(row),
    ]));
  }

  Future<void> _rowMenu(FlowOutlineRow row) async {
    final choice = await showFlowOutlineMenu(
      context,
      row: row,
      canRetype: _controller.caps.canRetype,
    );
    if (choice == null || !mounted) return;
    final step = () => FlowStepDefaults.step(
          _controller.freshId('step'),
          'task',
          prompt: AppLocalizations.of(context).flow_newStepPrompt,
        );
    await switch (choice.action) {
      FlowOutlineMenuAction.insertChild => _controller.applyOps([
          FlowOutlineOps.insertChild(row.node, step(), branch: choice.branch),
        ]),
      FlowOutlineMenuAction.moveIntoPrevious =>
        _controller.applyOps([FlowOutlineOps.moveIntoPrevious(row)]),
      FlowOutlineMenuAction.wrapWithPrevious => _controller.applyOps(
          FlowOutlineOps.wrapWithPrevious(
            row,
            choice.kind!,
            _controller.freshId(choice.kind!),
          ),
        ),
      // 改类型只发一个 retype：保留 id 和 desc / when / retry，主机搬子节点。
      FlowOutlineMenuAction.retype =>
        _controller.applyOps([FlowOutlineOps.retype(row, choice.kind!)]),
    };
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

  void _openInspector(FlowNode node) {
    setState(() => _selectedId = node.id);
    final schema = _controller.schema;
    if (schema == null || _controller.busy) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => FlowNodeInspector(
        node: node,
        schema: schema,
        roles: peekRoles(_controller.yaml),
        onPickAgent: _pickAgent,
        onApply: (changes) {
          Navigator.pop(sheet);
          if (changes.isEmpty) return;
          unawaited(_controller.applyOps([
            for (final e in changes.entries)
              FlowEditOps.set(node.id, e.key, e.value),
          ]));
        },
        onDelete: () {
          Navigator.pop(sheet);
          unawaited(_controller.applyOps([FlowEditOps.delete(node.id)]));
        },
        onWrap: (kind) {
          Navigator.pop(sheet);
          unawaited(_controller.applyOps([
            FlowEditOps.wrap(
              nodeId: node.id,
              kind: kind,
              wrapperId: _controller.freshId(kind),
            ),
          ]));
        },
        onUnwrap: () {
          Navigator.pop(sheet);
          unawaited(_controller.applyOps([FlowEditOps.unwrap(node.id)]));
        },
        onAddAfter: () {
          Navigator.pop(sheet);
          final row = _rowFor(node.id);
          if (row == null) return;
          // 走大纲那一行：`if` 里要带上 branch，否则新节点会落进 `then`。
          unawaited(_controller.applyOps([
            FlowOutlineOps.insertAfter(
              row,
              FlowStepDefaults.step(
                _controller.freshId('step'),
                'task',
                prompt: AppLocalizations.of(context).flow_newStepPrompt,
              ),
            ),
          ]));
        },
      ),
    );
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

  /// 打开 Agent 选择器，返回选中的 id。
  Future<String?> _pickAgent() async {
    if (_agents.isEmpty) {
      final agents = await LocalDatabaseService().getAllRemoteAgents();
      if (!mounted) return null;
      setState(() => _agents = agents);
    }
    final l10n = AppLocalizations.of(context);
    final picked = await showJadeSlipAgentPicker(
      context,
      agents: _agents,
      title: l10n.flow_executorPickAgent,
    );
    return picked?.id;
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
          appBar: AppBar(
            title: Text(l10n.flow_designTitle(widget.name)),
            actions: [
              if (c.revision > 0)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(l10n.flow_revisionLabel(c.revision),
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                ),
              IconButton(
                tooltip: l10n.flow_diffToggle,
                icon: Icon(Icons.difference_outlined,
                    color: c.showDiff
                        ? Theme.of(context).colorScheme.primary
                        : null),
                onPressed: c.loading || c.busy ? null : c.toggleDiff,
              ),
              IconButton(
                tooltip: l10n.flow_rehearse,
                icon: const Icon(Icons.play_circle_outline),
                onPressed: c.loading || c.busy ? null : c.startRehearsal,
              ),
              IconButton(
                tooltip: l10n.flow_save,
                icon: c.saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                onPressed: c.loading || c.busy || !c.dirty ? null : c.save,
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(child: _body(l10n)),
              if (_talkBar(l10n) case final bar?) bar,
              // 桌面端（C.6）：左边看图，右边直接改 YAML。手机只给看源码。
              if (_yamlBar(l10n) case final bar?) bar,
            ],
          ),
        );
      },
    );
  }

  Widget _body(AppLocalizations l10n) {
    final c = _controller;
    if (c.loading) return const Center(child: CircularProgressIndicator());
    if (c.loadFailed) return Center(child: Text(l10n.flow_designLoadFailed));
    final theme = Theme.of(context);
    final diff = c.diff;
    final rehearsal = c.rehearsal;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (rehearsal.active) _rehearsalCard(l10n, theme),
        for (final d in c.diagnostics)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              d.at.isEmpty ? d.message : '[${d.at}] ${d.message}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: d.isError ? theme.colorScheme.error : Colors.orange,
              ),
            ),
          ),
        if (c.showDiff && diff != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              diff.isEmpty
                  ? l10n.flow_diffNone
                  : l10n.flow_diffSummary(
                      diff.nodes.length + diff.header.length),
              style: theme.textTheme.labelLarge,
            ),
          ),
        if (diff != null && diff.removed.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              l10n.flow_diffRemoved(diff.removed.map((n) => n.id).join(', ')),
              style: theme.textTheme.bodySmall?.copyWith(
                decoration: TextDecoration.lineThrough,
                color: Colors.grey,
              ),
            ),
          ),
        // 能改就画可编辑的大纲（带分支、上移下移、加一步）；否则画只读的那棵。
        if (canEdit && !rehearsal.active)
          FlowOutlineTree(
            rows: _rows(),
            canEdit: true,
            branchesLabelled: c.caps.branchesLabelled,
            selectedId: _selectedId,
            errorCounts: _errorCounts(),
            collapsed: _collapsed,
            badgeFor: diff == null
                ? null
                : (row) {
                    final change = diff.of(row.node.id);
                    return switch (change?.change) {
                      FlowChange.added => (l10n.flow_diffAdded, Colors.green),
                      FlowChange.changed =>
                        (l10n.flow_diffChanged, Colors.amber),
                      _ => null,
                    };
                  },
            onTapRow: (row) => _openInspector(row.node),
            onToggleCollapse: _toggleCollapse,
            onAddAfter: _addAfter,
            onMoveUp: (row) => _move(row, up: true),
            onMoveDown: (row) => _move(row, up: false),
            onDelete: _delete,
            onMenu: _rowMenu,
          )
        else
          FlowNodeTree(
            nodes: rehearsal.view(c.tree),
            onTapNode: canEdit ? _openInspector : null,
            onLongPressNode: canTalk ? _toggleSelected : null,
            selectedIds: _selected,
            badgeFor: diff == null
                ? null
                : (node) {
                    final change = diff.of(node.id);
                    return switch (change?.change) {
                      FlowChange.added => (l10n.flow_diffAdded, Colors.green),
                      FlowChange.changed =>
                        (l10n.flow_diffChanged, Colors.amber),
                      _ => null,
                    };
                  },
          ),
        if (_reply.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(_reply.toString()),
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
            leading: const Icon(Icons.play_circle_outline),
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

  /// 桌面端的源码条（C.6）：折叠着只占一行，展开后能直接改 YAML。
  ///
  /// 改完同样走 `flow_validate_req`（主机判），有错误就不让保存。手机上只读。
  Widget? _yamlBar(AppLocalizations l10n) {
    final wide = MediaQuery.of(context).size.width >= 900;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const ValueKey('yaml-bar'),
            dense: true,
            leading: const Icon(Icons.data_object),
            title: Text(l10n.flow_source),
            trailing: Icon(_showYaml
                ? Icons.keyboard_arrow_down
                : Icons.keyboard_arrow_up),
            onTap: () => setState(() => _showYaml = !_showYaml),
          ),
          if (_showYaml)
            SizedBox(
              height: 260,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: FlowYamlEditor(
                  yaml: _controller.yaml,
                  readOnly: !wide,
                  validate: (text) =>
                      _controller.client.validate(widget.peerId, text),
                  applyLabel: l10n.flow_sourceApply,
                  onApply: (edited, checked) {
                    setState(() => _showYaml = false);
                    unawaited(_controller.applySource(edited, checked));
                  },
                ),
              ),
            ),
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
            if (_selected.isNotEmpty)
              Wrap(
                spacing: 6,
                children: [
                  for (final id in _selected)
                    InputChip(
                      key: ValueKey('sel-$id'),
                      label: Text(id),
                      onDeleted: () => setState(() => _selected.remove(id)),
                    ),
                ],
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
