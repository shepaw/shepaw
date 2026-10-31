import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/folded_sessions.dart';
import '../peer/services/hub_folded_sessions.dart';
import '../widgets/session_folders.dart';
import 'flow_run_screen.dart';
import 'group_view_screen.dart';
import 'session_history_screen.dart';

/// 会话搜索（折叠方案 §2.3）：平铺的私聊和五个折叠组一起找，结果带来源角标。
///
/// 主机是权威，搜索在主机上做；App 只发关键词、画结果。折叠组里的会话只读，
/// 点开是它那份只读记录（工作流节点进运行视图，群聊进群聊视角）。
class SessionSearchScreen extends StatefulWidget {
  const SessionSearchScreen({
    super.key,
    required this.peerId,
    this.agentId = '',
    this.client,
    this.debounce = const Duration(milliseconds: 300),
  });

  final String peerId;

  /// 只搜这一个 Agent；为空是全部（惜宝不在范围内）。
  final String agentId;
  final HubFoldedSessions? client;
  final Duration debounce;

  @override
  State<SessionSearchScreen> createState() => _SessionSearchScreenState();
}

class _SessionSearchScreenState extends State<SessionSearchScreen> {
  late final HubFoldedSessions _client = widget.client ?? HubFoldedSessions();
  final TextEditingController _field = TextEditingController();
  List<SessionSearchHit> _hits = const [];
  Timer? _debounce;
  bool _searching = false;
  bool _asked = false;

  @override
  void initState() {
    super.initState();
    _field.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _field.removeListener(_onChanged);
    _field.dispose();
    super.dispose();
  }

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(widget.debounce, () => unawaited(_search()));
  }

  Future<void> _search() async {
    final query = _field.text.trim();
    setState(() => _searching = true);
    final hits = await _client.search(
      widget.peerId,
      query,
      agentId: widget.agentId,
    );
    if (!mounted) return;
    setState(() {
      _hits = hits;
      _searching = false;
      _asked = query.isNotEmpty;
    });
  }

  void _open(SessionSearchHit hit) {
    final origin = hit.origin;
    if (!hit.readOnly) return;
    if (origin.kind == 'flow' && origin.runId.isNotEmpty) {
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => FlowRunScreen(
          peerId: widget.peerId,
          runId: origin.runId,
          title: hit.title,
        ),
      ));
      return;
    }
    if (origin.kind == 'group' && origin.groupId.isNotEmpty) {
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => GroupViewScreen(
          peerId: widget.peerId,
          agentId: hit.agentId,
          groupId: origin.groupId,
          groupSessionId: origin.groupSessionId,
          title: hit.title,
          foldedSessionId: hit.sessionId,
          client: _client,
        ),
      ));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SessionHistoryScreen.forFolderSession(
        peerId: widget.peerId,
        agentId: hit.agentId,
        sessionId: hit.sessionId,
        title: hit.title,
        client: _client,
      ),
    ));
  }

  /// 来源角标的文案。`private` 之外都按折叠组的名字显示。
  String _badge(AppLocalizations l10n, SessionSearchHit hit) {
    final kind = SessionFolderKind.parse(hit.origin.kind);
    if (kind == null) return hit.source;
    return sessionFolderLabel(l10n, kind);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.sessionSearchTitle)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              key: const ValueKey('session-search-field'),
              controller: _field,
              autofocus: true,
              decoration: InputDecoration(
                hintText: l10n.sessionSearchHint,
                prefixIcon: const Icon(Icons.search),
                isDense: true,
              ),
              onSubmitted: (_) => unawaited(_search()),
            ),
          ),
          if (_searching)
            const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          Expanded(child: _results(l10n, theme)),
        ],
      ),
    );
  }

  Widget _results(AppLocalizations l10n, ThemeData theme) {
    if (_hits.isEmpty) {
      if (!_asked) return const SizedBox.shrink();
      return Center(child: Text(l10n.sessionSearchEmpty));
    }
    return ListView(
      children: [
        for (final hit in _hits)
          ListTile(
            leading: Icon(
                hit.readOnly ? Icons.lock_outline : Icons.chat_bubble_outline),
            title: Text(hit.title.isEmpty ? hit.sessionId : hit.title),
            subtitle: hit.snippet == null ? null : Text(hit.snippet!),
            trailing: Chip(
              label: Text(_badge(l10n, hit)),
              visualDensity: VisualDensity.compact,
            ),
            onTap: hit.readOnly ? () => _open(hit) : null,
          ),
      ],
    );
  }
}
