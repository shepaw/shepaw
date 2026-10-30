import 'dart:async';

import 'package:flutter/material.dart';

import '../peer/models/folded_sessions.dart';
import '../peer/services/hub_folded_sessions.dart';

/// 群聊视角（折叠方案 §2.2）：这个 Agent 在某个群会话里说过的话，只读。
/// 可以分叉到私聊接着聊。
class GroupViewScreen extends StatefulWidget {
  const GroupViewScreen({
    super.key,
    required this.peerId,
    required this.agentId,
    required this.groupId,
    required this.groupSessionId,
    this.title,
    this.foldedSessionId,
    this.client,
    this.onForked,
  });

  final String peerId;
  final String agentId;
  final String groupId;
  final String groupSessionId;
  final String? title;

  /// 折叠组里这一项对外的 session_id，分叉要用；没有就不显示分叉。
  final String? foldedSessionId;
  final HubFoldedSessions? client;
  final void Function(String sessionId)? onForked;

  @override
  State<GroupViewScreen> createState() => _GroupViewScreenState();
}

class _GroupViewScreenState extends State<GroupViewScreen> {
  late final HubFoldedSessions _client = widget.client ?? HubFoldedSessions();
  final List<GroupViewMessage> _messages = [];
  String _cursor = '';
  bool _hasMore = false;
  bool _loading = false;
  bool _failed = false;

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
    final page = await _client.groupView(
      widget.peerId,
      widget.agentId,
      widget.groupId,
      widget.groupSessionId,
      cursor: _cursor,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (page == null) {
        _failed = true;
        return;
      }
      if (page.reset) _messages.clear();
      _messages.addAll(page.messages);
      _cursor = page.cursor;
      _hasMore = page.hasMore;
    });
  }

  Future<void> _fork() async {
    final id = widget.foldedSessionId;
    if (id == null) return;
    final result = await _client.fork(widget.peerId, widget.agentId, id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result.sessionId == null ? (result.error ?? '分叉失败') : '已分叉到私聊'),
    ));
    if (result.sessionId != null) widget.onForked?.call(result.sessionId!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? '群聊中的发言'),
        actions: [
          if (widget.foldedSessionId != null)
            TextButton(onPressed: _fork, child: const Text('分叉到私聊')),
        ],
      ),
      body: Builder(builder: (context) {
        if (_messages.isEmpty) {
          if (_loading) return const Center(child: CircularProgressIndicator());
          if (_failed) {
            return Center(
              child: TextButton(onPressed: _more, child: const Text('读取失败，点此重试')),
            );
          }
          return const Center(child: Text('这个 Agent 在这个群会话里还没有发言'));
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final message in _messages)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(message.content),
                      if (message.createdAt.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(message.createdAt,
                              style: Theme.of(context).textTheme.bodySmall),
                        ),
                    ],
                  ),
                ),
              ),
            if (_hasMore)
              Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : TextButton(onPressed: _more, child: const Text('加载更多')),
              ),
          ],
        );
      }),
    );
  }
}
