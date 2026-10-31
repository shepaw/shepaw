import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/flow_models.dart';
import '../peer/pouch_turn_relay.dart';
import '../peer/services/hub_flow.dart';
import '../services/local_user_identity.dart';
import '../widgets/flow/flow_node_inspector.dart';
import '../widgets/flow/flow_node_tree.dart';

/// 流程设计视图（方案 C.3–C.5）：节点树 + 检查器直接改 + 与上一版的差异 + 演练。
///
/// App 不解析 YAML：每次改动都发给 Hub（`flow_edit_req`），用回来的节点树重画；
/// 不合法的地方在诊断里。保存才写进流程库成为新的 revision。
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
  late final HubFlow _client = widget.client ?? HubFlow();
  FlowSchema? _schema;
  String _baseYaml = '';
  String _yaml = '';
  int _revision = 0;
  List<FlowNode> _tree = const [];
  List<FlowDiagnostic> _diagnostics = const [];
  FlowDiff? _diff;
  bool _showDiff = false;
  bool _loading = true;
  bool _loadFailed = false;
  bool _saving = false;
  int _nextId = 1;

  bool get canTalk => _talkGroupId.isNotEmpty;

  /// 说话要发到哪个群。没直接给 `groupId` 时，群库（`group:<gid>`）本身就是群。
  /// `sessionId` 留空：主机取群 meta 的 current_session。
  String get _talkGroupId {
    if (widget.groupId.isNotEmpty) return widget.groupId;
    return widget.scope.startsWith('group:')
        ? widget.scope.substring('group:'.length)
        : '';
  }

  // 演练
  FlowRehearsal? _rehearsal;
  int _progress = 0;
  Timer? _timer;

  // 点选 + 说话（C.3）
  final Set<String> _selected = <String>{};
  final TextEditingController _composer = TextEditingController();
  final StringBuffer _reply = StringBuffer();
  bool _talking = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _composer.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final got =
        await _client.get(widget.peerId, widget.name, scope: widget.scope);
    final schema = await _client.schema(widget.peerId);
    if (!mounted) return;
    if (got == null || schema == null) {
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
      return;
    }
    final checked = await _client.validate(widget.peerId, got.yaml);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _schema = schema;
      _revision = got.revision;
      _baseYaml = checked?.yaml.isNotEmpty == true ? checked!.yaml : got.yaml;
      _yaml = _baseYaml;
      _tree = checked?.tree ?? const [];
      _diagnostics = checked?.diagnostics ?? const [];
    });
  }

  int get _errorCount => _diagnostics.where((d) => d.isError).length;

  Future<void> _applyOps(List<Map<String, dynamic>> ops) async {
    final result = await _client.edit(widget.peerId, _yaml, ops);
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    if (!result.reachable) {
      _snack(l10n.flow_hostNoReply);
      return;
    }
    final checked = result.result;
    if (checked == null) {
      _snack(result.error ?? l10n.flow_editFailed);
      return;
    }
    setState(() {
      _yaml = checked.yaml;
      _tree = checked.tree;
      _diagnostics = checked.diagnostics;
    });
    if (_showDiff) unawaited(_refreshDiff());
  }

  Future<void> _refreshDiff() async {
    final got = await _client.diff(
      widget.peerId,
      fromYaml: _baseYaml,
      toYaml: _yaml,
    );
    if (!mounted) return;
    setState(() => _diff = got.diff);
  }

  Future<void> _toggleDiff() async {
    setState(() => _showDiff = !_showDiff);
    if (_showDiff) await _refreshDiff();
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  String _freshId(String prefix) {
    String id;
    do {
      id = '$prefix-${_nextId++}';
    } while (_tree.any((n) => n.find((x) => x.id == id) != null));
    return id;
  }

  void _toggleSelected(FlowNode node) {
    if (_rehearsal != null) return;
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

  Future<void> _talk() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _talking) return;
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
          onAgentDone: (_, __, ___) => unawaited(_load()),
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
        unawaited(_load());
      }
    } catch (error) {
      if (mounted) _snack('$error');
    } finally {
      if (mounted) setState(() => _talking = false);
    }
    _composer.clear();
  }

  void _openInspector(FlowNode node) {
    final schema = _schema;
    if (schema == null || _rehearsal != null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => FlowNodeInspector(
        node: node,
        schema: schema,
        onApply: (changes) {
          Navigator.pop(sheet);
          if (changes.isEmpty) return;
          unawaited(_applyOps([
            for (final e in changes.entries)
              {
                'op': 'set',
                'node_id': node.id,
                'field': e.key,
                'value': e.value
              },
          ]));
        },
        onDelete: () {
          Navigator.pop(sheet);
          unawaited(_applyOps([
            {'op': 'delete', 'node_id': node.id},
          ]));
        },
        onWrap: (kind) {
          Navigator.pop(sheet);
          unawaited(_applyOps([
            {
              'op': 'wrap',
              'node_id': node.id,
              'kind': kind,
              'wrapper_id': _freshId(kind),
              if (kind == 'loop') 'max': 3,
            },
          ]));
        },
        onUnwrap: () {
          Navigator.pop(sheet);
          unawaited(_applyOps([
            {'op': 'unwrap', 'node_id': node.id},
          ]));
        },
        onAddAfter: () {
          Navigator.pop(sheet);
          final at = flowLocate(_tree, node.id);
          if (at == null) return;
          unawaited(_applyOps([
            {
              'op': 'insert',
              'parent_id': at.parent?.id ?? '',
              'index': at.index + 1,
              'step': {
                'id': _freshId('step'),
                'task': {
                  'prompt': AppLocalizations.of(context).flow_newStepPrompt,
                },
              },
            },
          ]));
        },
      ),
    );
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    if (_errorCount > 0) {
      _snack(l10n.flow_hasProblems(_errorCount));
      return;
    }
    setState(() => _saving = true);
    final result = await _client.save(widget.peerId, widget.name, _yaml,
        scope: widget.scope);
    if (!mounted) return;
    setState(() => _saving = false);
    if (!result.ok) {
      _snack(result.reachable
          ? (result.error ?? l10n.flow_saveFailed)
          : l10n.flow_hostNoReply);
      return;
    }
    final flow = result.data['flow'];
    final latest = flow is Map ? (flow['latest'] as num?)?.toInt() : null;
    setState(() {
      _baseYaml = _yaml;
      _revision = latest ?? _revision + 1;
      _diff = null;
      _showDiff = false;
    });
    _snack(l10n.flow_saved(_revision));
  }

  Future<void> _rehearse() async {
    final l10n = AppLocalizations.of(context);
    final got = await _client.rehearse(widget.peerId, _yaml);
    if (!mounted) return;
    final rehearsal = got.rehearsal;
    if (rehearsal == null) {
      _snack(got.error == null
          ? l10n.flow_hostNoReply
          : l10n.flow_rehearseFailed(got.error!));
      return;
    }
    _timer?.cancel();
    setState(() {
      _rehearsal = rehearsal;
      _progress = 0;
    });
    _timer = Timer.periodic(widget.stepInterval, (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _progress++);
      if (_progress > rehearsal.steps.length) timer.cancel();
    });
  }

  void _stopRehearsal() {
    _timer?.cancel();
    setState(() => _rehearsal = null);
  }

  /// 演练时画演练返回的树（循环按真实跑的轮数展开），按派活顺序点亮。
  List<FlowNode> get _shownTree {
    final rehearsal = _rehearsal;
    if (rehearsal == null) return _tree;
    final steps = rehearsal.steps;
    final doneCount = _progress.clamp(0, steps.length);
    final done = steps.take(doneCount > 0 ? doneCount - 1 : 0).toSet();
    final running = doneCount > 0 && doneCount <= steps.length
        ? steps[doneCount - 1]
        : null;
    final finished = _progress > steps.length;
    return [
      for (final node in rehearsal.tree)
        node.withProgress(
            finished ? steps.toSet() : done, finished ? null : running),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.flow_designTitle(widget.name)),
        actions: [
          if (_revision > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(l10n.flow_revisionLabel(_revision),
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
          IconButton(
            tooltip: l10n.flow_diffToggle,
            icon: Icon(Icons.difference_outlined,
                color:
                    _showDiff ? Theme.of(context).colorScheme.primary : null),
            onPressed: _loading || _rehearsal != null ? null : _toggleDiff,
          ),
          IconButton(
            tooltip: l10n.flow_rehearse,
            icon: const Icon(Icons.play_circle_outline),
            onPressed: _loading || _rehearsal != null ? null : _rehearse,
          ),
          IconButton(
            tooltip: l10n.flow_save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check),
            onPressed:
                _loading || _saving || _rehearsal != null || _yaml == _baseYaml
                    ? null
                    : _save,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _body(l10n)),
          if (_talkBar(l10n) case final bar?) bar,
        ],
      ),
    );
  }

  Widget _body(AppLocalizations l10n) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadFailed) return Center(child: Text(l10n.flow_designLoadFailed));
    final theme = Theme.of(context);
    final diff = _showDiff ? _diff : null;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_rehearsal != null)
          Card(
            color: theme.colorScheme.secondaryContainer,
            child: ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: Text(l10n.flow_rehearsing),
              trailing: TextButton(
                onPressed: _stopRehearsal,
                child: Text(l10n.flow_rehearseStop),
              ),
            ),
          ),
        for (final d in _diagnostics)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              d.at.isEmpty ? d.message : '[${d.at}] ${d.message}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: d.isError ? theme.colorScheme.error : Colors.orange,
              ),
            ),
          ),
        if (_showDiff && diff != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              diff.isEmpty
                  ? l10n.flow_diffNone
                  : l10n
                      .flow_diffSummary(diff.nodes.length + diff.header.length),
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
        FlowNodeTree(
          nodes: _shownTree,
          onTapNode: _openInspector,
          onLongPressNode: canTalk ? _toggleSelected : null,
          selectedIds: _selected,
          badgeFor: diff == null
              ? null
              : (node) {
                  final change = diff.of(node.id);
                  return switch (change?.change) {
                    FlowChange.added => (l10n.flow_diffAdded, Colors.green),
                    FlowChange.changed => (l10n.flow_diffChanged, Colors.amber),
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
