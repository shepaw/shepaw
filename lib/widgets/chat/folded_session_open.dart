import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/folded_sessions.dart';
import '../../peer/services/flow_session_open.dart';
import '../../peer/services/hub_folded_sessions.dart';
import '../../screens/flow_run_screen.dart';
import '../../screens/group_view_screen.dart';
import '../../screens/session_history_screen.dart';
import '../../utils/session_utils.dart';
import '../session_folders.dart';

// 会话 id 的格式守卫在服务层：运行页（FlowRunScreen）也要用它，避免两处
// 各写一份、各漏一类旧格式。
export '../../peer/services/flow_session_open.dart' show flowFoldedSessionId;

/// 命中里主机给的标题同样可能带引擎标签 / `[implicit]` 提示：清掉，清完没东西
/// 就退回会话 id。
String _hitTitle(SessionSearchHit hit) =>
    SessionUtils.cleanClaudeSessionTitle(hit.title) ?? hit.sessionId;

/// 一条搜索命中的来源角标文案。`private` 之外都按折叠组的名字显示。
String sessionSearchHitBadge(AppLocalizations l10n, SessionSearchHit hit) {
  final kind = SessionFolderKind.parse(hit.origin.kind);
  if (kind == null) return hit.source;
  return sessionFolderLabel(l10n, kind);
}

/// 折叠组里的 session id 能不能当主机会话 id 用。
///
/// 守卫本身在 [flowFoldedSessionId]（服务层），运行页也复用同一份。
///
/// 长按 / 菜单里的「查看运行」：跳回运行视图。
void pushFlowRunScreen(
  BuildContext context, {
  required String peerId,
  required String runId,
  required String title,
  VoidCallback? onDeleted,
}) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => FlowRunScreen(
      peerId: peerId,
      runId: runId,
      title: title,
      onDeleted: onDeleted,
    ),
  ));
}

/// 搜索命中 / 折叠行的次级入口。主点击已经改成打开会话，运行视图留在这里。
Future<void> showFlowRunActions(
  BuildContext context, {
  required String peerId,
  required String runId,
  required String title,
}) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.account_tree_outlined),
              title: Text(AppLocalizations.of(sheetContext).flow_viewRun),
              onTap: () {
                Navigator.pop(sheetContext);
                pushFlowRunScreen(context,
                    peerId: peerId, runId: runId, title: title);
              },
            ),
          ],
        ),
      ),
    );

/// 打开一条命中：私聊本来就在平铺列表里（调用方自己切），工作流节点优先打开
/// 它的 agent 会话（和私聊一样能继续聊 / 停止），群聊进群聊视角，其余走主机的
/// 会话历史。没有真会话 id 的旧条目仍退回运行视图。
///
/// 抽屉搜索和别处共用这一段，免得两处各写一份跳转。
void openSessionSearchHit(
  BuildContext context, {
  required String peerId,
  required SessionSearchHit hit,
  HubFoldedSessions? client,
}) {
  final origin = hit.origin;
  if (origin.kind == 'flow' && origin.runId.isNotEmpty) {
    final sessionId = flowFoldedSessionId(hit.sessionId);
    if (sessionId != null) {
      unawaited(openFlowNodeSession(
        peerId: peerId,
        sessionId: sessionId,
        remoteAgentId: hit.agentId,
        title: _hitTitle(hit),
      ));
      return;
    }
    pushFlowRunScreen(context,
        peerId: peerId, runId: origin.runId, title: _hitTitle(hit));
    return;
  }
  if (origin.kind == 'group' && origin.groupId.isNotEmpty) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => GroupViewScreen(
        peerId: peerId,
        agentId: hit.agentId,
        groupId: origin.groupId,
        groupSessionId: origin.groupSessionId,
        title: _hitTitle(hit),
        foldedSessionId: hit.sessionId,
        client: client,
      ),
    ));
    return;
  }
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => SessionHistoryScreen.forFolderSession(
      peerId: peerId,
      agentId: hit.agentId,
      sessionId: hit.sessionId,
      title: _hitTitle(hit),
      client: client,
    ),
  ));
}
