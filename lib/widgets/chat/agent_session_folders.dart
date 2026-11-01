import 'dart:async';

import 'package:flutter/material.dart';

import '../../peer/models/folded_sessions.dart';
import '../../peer/services/hub_folded_sessions.dart';
import '../../peer/services/peer_agent_client_service.dart';
import '../../screens/flow_run_screen.dart';
import '../../screens/group_view_screen.dart';
import '../../screens/session_history_screen.dart';
import '../session_folders.dart';
import 'folded_session_items.dart';

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
    this.refresh,
  });

  final String peerId;

  /// 主机上的 Agent id（不是本机的 RemoteAgent.id）。
  final String remoteAgentId;
  final Listenable? refreshTick;
  final HubFoldedSessions? client;

  /// 分叉成功：主机上多了一条私聊，调用方刷新平铺名单。
  final void Function(String sessionId)? onForked;

  /// 分叉后把主机名单再对齐一次，让新私聊立刻出现在平铺列表里。
  /// 测试里换成假的；为空时用 [PeerAgentClientService.refreshAgentSessions]。
  final Future<void> Function(String peerId, String remoteAgentId)? refresh;

  @override
  State<AgentSessionFolders> createState() => _AgentSessionFoldersState();
}

class _AgentSessionFoldersState extends State<AgentSessionFolders> {
  late final HubFoldedSessions _client = widget.client ?? HubFoldedSessions();
  List<SessionFolderSummary> _folders = const [];

  /// 当前展开的那一组；为空表示都收着。
  SessionFolderKind? _expanded;

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

  /// 分叉出来的新私聊要马上能在平铺列表里看到：主机名单再对齐一次，
  /// 顺手把折叠组的条数也刷一遍（分叉不改折叠组，但时间会变）。
  Future<void> _afterFork(String sessionId) async {
    widget.onForked?.call(sessionId);
    final refresh = widget.refresh;
    if (refresh == null) {
      await PeerAgentClientService.instance.refreshAgentSessions(
        peerId: widget.peerId,
        remoteAgentId: widget.remoteAgentId,
      );
    } else {
      await refresh(widget.peerId, widget.remoteAgentId);
    }
    await _load();
  }

  void _toggle(SessionFolderKind kind) {
    setState(() => _expanded = _expanded == kind ? null : kind);
  }

  /// 展开后点其中一项 → 打开它的只读记录。
  void _openSession(BuildContext context, FoldedSession session) {
    if (session.isFlow && session.runId.isNotEmpty) {
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => FlowRunScreen(
          peerId: widget.peerId,
          runId: session.runId,
          title: session.title,
          // 运行被删掉：节点会话也一起隐藏了，重刷一下条数。
          onDeleted: () => unawaited(_load()),
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
          onForked: (id) => unawaited(_afterFork(id)),
        ),
      ));
      return;
    }
    // 引擎客户端 / 终端 / 其他 Agent 发起：走主机的会话历史，只读，可分叉。
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SessionHistoryScreen.forFolderSession(
        peerId: widget.peerId,
        agentId: widget.remoteAgentId,
        sessionId: session.sessionId,
        title: session.title.isEmpty ? session.sessionId : session.title,
        client: _client,
        onForked: (id) => unawaited(_afterFork(id)),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_folders.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 一次只展开一组：抽屉就那么宽，几组同时铺开会把私聊挤出可视区。
        for (final folder in _folders) ...[
          SessionFolderTile(
            summary: folder,
            expanded: _expanded == folder.kind,
            onTap: () => _toggle(folder.kind),
          ),
          if (_expanded == folder.kind)
            SessionFolderItems(
              key: ValueKey<SessionFolderKind>(folder.kind),
              peerId: widget.peerId,
              agentId: widget.remoteAgentId,
              folder: folder.kind,
              client: _client,
              onOpen: (session) => _openSession(context, session),
              onForked: (id) => unawaited(_afterFork(id)),
            ),
        ],
        const Divider(height: 1),
      ],
    );
  }
}
