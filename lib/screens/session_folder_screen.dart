import 'dart:async';

import 'package:flutter/material.dart';

import '../peer/models/folded_sessions.dart';
import '../peer/services/hub_folded_sessions.dart';

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
      content: Text(id == null ? (result.error ?? '分叉失败') : '已分叉到私聊'),
    ));
    if (id != null) widget.onForked?.call(id);
  }

  String _subtitle(FoldedSession session) {
    final parts = <String>[];
    if (session.isFlow && session.nodeKey.isNotEmpty) {
      parts.add('节点 ${session.nodeKey}');
    }
    if (session.fromAgent.isNotEmpty) parts.add('来自 ${session.fromAgent}');
    if (session.hostName.isNotEmpty) parts.add(session.hostName);
    if (session.messageCount != null) parts.add('${session.messageCount} 条');
    return parts.join(' · ');
  }

  /// 工作流按运行分组，其余按时间平铺（折叠方案 §2.2）。
  List<Widget> _rows() {
    final rows = <Widget>[];
    String? lastRun;
    for (final session in _items) {
      if (widget.folder == SessionFolderKind.flow &&
          session.runId.isNotEmpty &&
          session.runId != lastRun) {
        lastRun = session.runId;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('运行 ${session.runId}',
              style: Theme.of(context).textTheme.labelMedium),
        ));
      }
      rows.add(ListTile(
        title: Text(session.title.isEmpty ? session.sessionId : session.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: _subtitle(session).isEmpty ? null : Text(_subtitle(session)),
        onTap: widget.onOpen == null ? null : () => widget.onOpen!(session),
        trailing: PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: (_) => _fork(session),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'fork', child: Text('分叉到私聊')),
          ],
        ),
      ));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.folder.label)),
      body: Builder(builder: (context) {
        if (_items.isEmpty) {
          if (_loading) return const Center(child: CircularProgressIndicator());
          if (_failed) {
            return Center(
              child: TextButton(onPressed: _more, child: const Text('读取失败，点此重试')),
            );
          }
          return const Center(child: Text('这里还没有会话'));
        }
        return ListView(
          children: [
            ..._rows(),
            if (_cursor != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Center(
                  child: _loading
                      ? const CircularProgressIndicator()
                      : TextButton(
                          onPressed: _more, child: const Text('加载更多')),
                ),
              ),
          ],
        );
      }),
    );
  }
}
