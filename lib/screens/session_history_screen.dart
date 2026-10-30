import 'dart:async';

import 'package:flutter/material.dart';

import '../peer/services/hub_folded_sessions.dart';
import '../peer/services/peer_agent_client_service.dart';

/// 折叠组里引擎客户端 / 终端 / 其他 Agent 发起的会话的只读记录（折叠方案 §2.2）。
/// 数据走现成的 `agent_session_history_req`，顺着游标往后翻；可以分叉到私聊。
class SessionHistoryScreen extends StatefulWidget {
  const SessionHistoryScreen({
    super.key,
    required this.title,
    required this.loadPage,
    this.fork,
    this.onForked,
  });

  final String title;

  /// 取一页；`cursor` 为空取第一页。测试里换成假的。
  final Future<PeerHistoryPage> Function(String? cursor) loadPage;

  /// 分叉到私聊，返回新会话 id 或错误；为空则不显示分叉入口。
  final Future<({String? sessionId, String? error})> Function()? fork;
  final void Function(String sessionId)? onForked;

  /// 按折叠组里的一项构造，走主机的会话历史。
  factory SessionHistoryScreen.forFolderSession({
    Key? key,
    required String peerId,
    required String agentId,
    required String sessionId,
    required String title,
    HubFoldedSessions? client,
    PeerAgentClientService? service,
    void Function(String sessionId)? onForked,
  }) {
    final hub = client ?? HubFoldedSessions();
    final svc = service ?? PeerAgentClientService.instance;
    return SessionHistoryScreen(
      key: key,
      title: title,
      loadPage: (cursor) => svc.fetchFolderSessionHistory(
        peerId: peerId,
        remoteAgentId: agentId,
        sessionId: sessionId,
        cursor: cursor,
        limit: 100,
      ),
      fork: () => hub.fork(peerId, agentId, sessionId),
      onForked: onForked,
    );
  }

  @override
  State<SessionHistoryScreen> createState() => _SessionHistoryScreenState();
}

class _SessionHistoryScreenState extends State<SessionHistoryScreen> {
  final List<PeerHistoryMessage> _messages = [];
  String? _cursor;
  bool _hasMore = false;
  bool _loading = false;
  bool _failed = false;
  bool _loadedOnce = false;

  @override
  void initState() {
    super.initState();
    unawaited(_more());
  }

  Future<void> _more() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final page = await widget.loadPage(_cursor);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (!page.completed) {
        _failed = true;
        return;
      }
      _loadedOnce = true;
      if (page.reset) _messages.clear();
      _messages.addAll(page.messages);
      _cursor = page.cursor;
      _hasMore = page.hasMore;
    });
  }

  Future<void> _fork() async {
    final result = await widget.fork!();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          result.sessionId == null ? (result.error ?? '分叉失败') : '已分叉到私聊'),
    ));
    if (result.sessionId != null) widget.onForked?.call(result.sessionId!);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (widget.fork != null)
            TextButton(onPressed: _fork, child: const Text('分叉到私聊')),
        ],
      ),
      body: Builder(builder: (context) {
        if (_messages.isEmpty) {
          if (_loading) return const Center(child: CircularProgressIndicator());
          if (_failed) {
            return Center(
              child: TextButton(
                  onPressed: _more, child: const Text('读取失败，点此重试')),
            );
          }
          return Center(
            child: Text(_loadedOnce ? '主机上没有这个会话可显示的记录' : ''),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final message in _messages)
              Align(
                alignment: message.role == 'user'
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.all(10),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.85,
                  ),
                  decoration: BoxDecoration(
                    color: message.role == 'user'
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(message.content),
                ),
              ),
            if (_hasMore)
              Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : TextButton(
                        onPressed: _more, child: const Text('加载更多')),
              ),
          ],
        );
      }),
    );
  }
}
