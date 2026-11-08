import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_models.dart';
import '../../peer/pouch_turn_relay.dart';
import '../../peer/services/hub_flow.dart';
import '../../services/local_user_identity.dart';
import 'flow_inspector_header.dart';
import 'flow_node_inspector.dart';
import 'flow_node_tree.dart';

/// 手机上的「步骤」页：只读看结构，可以点开详情，也可以挑几步跟群主说。
class FlowStepsPane extends StatefulWidget {
  const FlowStepsPane({
    super.key,
    required this.client,
    required this.peerId,
    required this.name,
    this.scope = '',
    this.draftBanner,
  });

  final HubFlow client;
  final String peerId;
  final String name;
  final String scope;
  final Widget? draftBanner;

  @override
  State<FlowStepsPane> createState() => _FlowStepsPaneState();
}

class _FlowStepsPaneState extends State<FlowStepsPane> {
  List<FlowNode> _tree = const [];
  FlowSchema? _schema;
  bool _loading = true;
  bool _selecting = false;
  bool _showHint = false;
  final Set<String> _selected = {};
  final Set<String> _flash = {};
  final TextEditingController _composer = TextEditingController();
  final StringBuffer _reply = StringBuffer();
  bool _talking = false;

  bool get _canTalk => widget.scope.startsWith('group:');

  String get _groupId => widget.scope.startsWith('group:')
      ? widget.scope.substring('group:'.length)
      : '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_hint());
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  Future<void> _hint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const key = 'flow_steps_select_hint_seen';
      if (prefs.getBool(key) == true) return;
      if (!mounted) return;
      setState(() => _showHint = true);
      await prefs.setBool(key, true);
    } catch (_) {}
  }

  Future<void> _load() async {
    final got = await widget.client.get(
      widget.peerId,
      widget.name,
      scope: widget.scope,
    );
    final schema = await widget.client.schema(widget.peerId);
    if (got == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final checked = await widget.client.validate(widget.peerId, got.yaml);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _schema = schema;
      _tree = checked?.tree ?? const [];
    });
  }

  void _open(FlowNode node) {
    final schema = _schema;
    if (schema == null) return;
    final l10n = AppLocalizations.of(context);
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
            Row(
              children: [
                Expanded(
                  child: Text('${flowKindName(l10n, node.kind)}  ${node.id}',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(sheet),
                ),
              ],
            ),
            FlowNodeInspector(
              node: node,
              schema: schema,
              readOnly: true,
              tree: _tree,
            ),
            if (_canTalk)
              FilledButton(
                key: const ValueKey('talk-about-step'),
                onPressed: () {
                  setState(() => _selected
                    ..clear()
                    ..add(node.id));
                  Navigator.pop(sheet);
                },
                child: Text(l10n.flow_talkAboutStep),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _talk() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _talking || !_canTalk) return;
    final before = {
      for (final node in _flatten(_tree)) node.id: node.desc ?? '',
    };
    setState(() {
      _talking = true;
      _reply.clear();
    });
    try {
      await PouchTurnRelay.instance.forwardGroup(
        hostPeerId: widget.peerId,
        channelId: _groupId,
        content: text,
        userId: LocalUserIdentity.id,
        userName: LocalUserIdentity.displayName,
        flowContext: {
          'flow': {'ref': '${widget.scope}/${widget.name}'},
          'selection': _selected.toList(),
        },
        onStreamChunk: (_, __, chunk) {
          if (!mounted) return;
          setState(() => _reply.write(chunk));
        },
        onAgentDone: (_, __, ___) async {
          await _load();
          if (!mounted) return;
          final after = {
            for (final node in _flatten(_tree)) node.id: node.desc ?? '',
          };
          setState(() {
            _flash
              ..clear()
              ..addAll(after.keys.where((id) => before[id] != after[id]));
          });
        },
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('$error')),
        );
      }
    } finally {
      if (mounted) setState(() => _talking = false);
    }
    _composer.clear();
  }

  List<FlowNode> _flatten(List<FlowNode> nodes) => [
        for (final node in nodes) ...[node, ..._flatten(node.children)],
      ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _selecting
                      ? l10n.flow_stepsSelected(_selected.length)
                      : l10n.flow_stepsReadOnly,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (_canTalk)
                TextButton(
                  key: const ValueKey('steps-select'),
                  onPressed: () => setState(() {
                    _selecting = !_selecting;
                    if (!_selecting) _showHint = false;
                  }),
                  child: Text(
                      _selecting ? l10n.flow_stepsDone : l10n.flow_stepsSelect),
                ),
            ],
          ),
        ),
        if (widget.draftBanner != null) widget.draftBanner!,
        if (_showHint)
          MaterialBanner(
            content: Text(l10n.flow_stepsHint),
            actions: [
              TextButton(
                onPressed: () => setState(() => _showHint = false),
                child: Text(l10n.common_ok),
              ),
            ],
          ),
        Expanded(
          child: ListView(
            key: const ValueKey('flow-steps-tree'),
            padding: const EdgeInsets.all(12),
            children: [
              FlowNodeTree(
                nodes: _tree,
                selectionMode: _selecting,
                selectedIds: _selected,
                onTapNode: (node) {
                  if (_selecting) {
                    setState(() {
                      if (!_selected.add(node.id)) _selected.remove(node.id);
                    });
                  } else {
                    _open(node);
                  }
                },
                onLongPressNode: _canTalk
                    ? (node) => setState(() {
                          _selecting = true;
                          _selected.add(node.id);
                        })
                    : null,
              ),
            ],
          ),
        ),
        if (_canTalk) _talkBar(l10n),
      ],
    );
  }

  Widget _talkBar(AppLocalizations l10n) {
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
                  padding: const EdgeInsets.all(12),
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
                    key: const ValueKey('steps-talk-input'),
                    controller: _composer,
                    decoration: InputDecoration(
                      hintText: l10n.flow_talkHint,
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('steps-talk-send'),
                  onPressed: _talking ? null : _talk,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
