import 'dart:async';

import 'package:flutter/material.dart';

import '../../peer/models/folded_sessions.dart';
import '../../peer/services/hub_folded_sessions.dart';
import '../../screens/flow_run_screen.dart';
import '../../screens/group_view_screen.dart';
import '../../screens/session_folder_screen.dart';
import '../session_folders.dart';

/// 私聊会话列表顶部的折叠组（折叠方案 §2.1）：群聊、其他 Agent 发起、工作流、
/// 引擎客户端、引擎终端，只在不为空时出现。
///
/// 主机是权威：这里自己向主机要摘要，主机没回（离线、旧版本不认折叠视图）就
/// 什么都不画，不影响原来的列表。
class AgentSessionFolders extends StatefulWidget {
  const AgentSessionFolders({
    super.key,
    required this.peerId,
    required this.remoteAgentId,
    this.refreshTick,
    this.client,
    this.onForked,
  });

  final String peerId;

  /// 主机上的 Agent id（不是本机的 RemoteAgent.id）。
  final String remoteAgentId;
  final Listenable? refreshTick;
  final HubFoldedSessions? client;

  /// 分叉成功：主机上多了一条私聊，调用方刷新平铺名单。
  final void Function(String sessionId)? onForked;

  @override
  State<AgentSessionFolders> createState() => _AgentSessionFoldersState();
}

class _AgentSessionFoldersState extends State<AgentSessionFolders> {
  late final HubFoldedSessions _client = widget.client ?? HubFoldedSessions();
  List<SessionFolderSummary> _folders = const [];

  @override
  void initState() {
    super.initState();
    widget.refreshTick?.addListener(_load);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.refreshTick?.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final summary = await _client.summary(widget.peerId, widget.remoteAgentId);
    if (!mounted || summary == null) return;
    setState(() => _folders = summary.folders);
  }

  void _open(SessionFolderKind kind) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => SessionFolderScreen(
        peerId: widget.peerId,
        agentId: widget.remoteAgentId,
        folder: kind,
        client: _client,
        onOpen: (session) => _openSession(context, session),
        onForked: (id) {
          widget.onForked?.call(id);
          unawaited(_load());
        },
      ),
    ));
  }

  /// 工作流节点跳到运行视图，群聊跳到群聊视角；其余来源的只读记录还没有页面，先提示可以分叉。
  void _openSession(BuildContext context, FoldedSession session) {
    if (session.isFlow && session.runId.isNotEmpty) {
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => FlowRunScreen(
          peerId: widget.peerId,
          runId: session.runId,
          title: session.title,
        ),
      ));
      return;
    }
    if (session.isGroup && session.groupId.isNotEmpty) {
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => GroupViewScreen(
          peerId: widget.peerId,
          agentId: widget.remoteAgentId,
          groupId: session.groupId,
          groupSessionId: session.groupSessionId,
          title: session.title,
          foldedSessionId: session.sessionId,
          client: _client,
          onForked: widget.onForked,
        ),
      ));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('这类会话是只读的，可以从右侧菜单分叉到私聊后继续聊')),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_folders.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final folder in _folders)
          SessionFolderTile(summary: folder, onTap: () => _open(folder.kind)),
        const Divider(height: 1),
      ],
    );
  }
}
