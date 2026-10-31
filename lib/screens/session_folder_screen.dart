import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/folded_sessions.dart';
import '../peer/services/hub_folded_sessions.dart';
import '../widgets/session_folders.dart';
import 'flow_library_screen.dart';

/// 折叠组明细（折叠方案 §2.2）：只读，可以分叉到私聊。分页按主机给的游标走。
class SessionFolderScreen extends StatefulWidget {
  const SessionFolderScreen({
    super.key,
    required this.peerId,
    required this.agentId,
    required this.folder,
    this.parentSession = '',
    this.client,
    this.onOpen,
    this.onForked,
  });

  final String peerId;
  final String agentId;
  final SessionFolderKind folder;
  final String parentSession;
  final HubFoldedSessions? client;

  /// 点一项：打开它的只读记录（工作流节点走运行视图，群聊走"在群里打开"）。
  final void Function(FoldedSession session)? onOpen;

  /// 分叉成功后，新私聊会话的 id；调用方在这里刷新平铺名单。
  final void Function(String sessionId)? onForked;

  @override
  State<SessionFolderScreen> createState() => _SessionFolderScreenState();
}

class _SessionFolderScreenState extends State<SessionFolderScreen> {
  late final HubFoldedSessions _client = widget.client ?? HubFoldedSessions();
  final List<FoldedSession> _items = [];
  String? _cursor;
  bool _loading = false;
  bool _failed = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    unawaited(_more());
  }

  Future<void> _more() async {
    if (_loading || (_started && _cursor == null)) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final page = await _client.page(
      widget.peerId,
      widget.agentId,
      widget.folder,
      cursor: _cursor ?? '',
      parentSession: widget.parentSession,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _started = true;
      if (page == null) {
        _failed = true;
        // 第一页失败时允许重试。
        if (_items.isEmpty) _started = false;
        return;
      }
      _items.addAll(page.items);
      _cursor = page.cursor;
    });
  }

  Future<void> _fork(FoldedSession session) async {
    final result =
        await _client.fork(widget.peerId, widget.agentId, session.sessionId);
    if (!mounted) return;
    final id = result.sessionId;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(id == null
          ? (result.error ?? AppLocalizations.of(context).folder_forkFailed)
          : AppLocalizations.of(context).folder_forked),
    ));
    if (id != null) widget.onForked?.call(id);
  }

  String _subtitle(AppLocalizations l10n, FoldedSession session) {
    final parts = <String>[];
    if (session.isFlow && session.nodeKey.isNotEmpty) {
      parts.add(l10n.folder_node(session.nodeKey));
    }
    if (session.fromAgent.isNotEmpty)
      parts.add(l10n.folder_from(session.fromAgent));
    if (session.hostName.isNotEmpty) parts.add(session.hostName);
    if (session.messageCount != null)
      parts.add(l10n.folder_messageCount(session.messageCount!));
    return parts.join(' · ');
  }

  /// 工作流按运行分组，其余按时间平铺（折叠方案 §2.2）。
  List<Widget> _rows(AppLocalizations l10n) {
    final rows = <Widget>[];
    String? lastRun;
    for (final session in _items) {
      if (widget.folder == SessionFolderKind.flow &&
          session.runId.isNotEmpty &&
          session.runId != lastRun) {
        lastRun = session.runId;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(l10n.folder_runHeader(session.runId),
              style: Theme.of(context).textTheme.labelMedium),
        ));
      }
      rows.add(ListTile(
        title: Text(session.title.isEmpty ? session.sessionId : session.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: _subtitle(l10n, session).isEmpty
            ? null
            : Text(_subtitle(l10n, session)),
        onTap: widget.onOpen == null ? null : () => widget.onOpen!(session),
        trailing: PopupMenuButton<String>(
          tooltip: l10n.folder_more,
          onSelected: (_) => _fork(session),
          itemBuilder: (_) => [
            PopupMenuItem(value: 'fork', child: Text(l10n.folder_fork)),
          ],
        ),
      ));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(sessionFolderLabel(l10n, widget.folder)),
        actions: [
          // 工作流组顺手带上流程库的入口：设计、演练、运行都从这里进。
          if (widget.folder == SessionFolderKind.flow)
            IconButton(
              tooltip: l10n.flow_libraryTitle,
              icon: const Icon(Icons.account_tree_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => FlowLibraryScreen(peerId: widget.peerId),
                ),
              ),
            ),
        ],
      ),
      body: Builder(builder: (context) {
        if (_items.isEmpty) {
          if (_loading) return const Center(child: CircularProgressIndicator());
          if (_failed) {
            return Center(
              child:
                  TextButton(onPressed: _more, child: Text(l10n.folder_retry)),
            );
          }
          return Center(child: Text(l10n.folder_empty));
        }
        return ListView(
          children: [
            ..._rows(l10n),
            if (_cursor != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Center(
                  child: _loading
                      ? const CircularProgressIndicator()
                      : TextButton(
                          onPressed: _more, child: Text(l10n.folder_loadMore)),
                ),
              ),
          ],
        );
      }),
    );
  }
}
