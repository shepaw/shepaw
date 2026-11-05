import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/folded_sessions.dart';
import '../../peer/services/hub_folded_sessions.dart';
import '../../screens/flow_run_screen.dart';
import '../../screens/group_view_screen.dart';
import '../../screens/session_history_screen.dart';
import '../../utils/session_utils.dart';
import '../session_folders.dart';

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

/// 打开一条命中：私聊本来就在平铺列表里（调用方自己切），这里只管只读记录 ——
/// 工作流节点进运行视图、群聊进群聊视角、其余走主机的会话历史。
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
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FlowRunScreen(
        peerId: peerId,
        runId: origin.runId,
        title: _hitTitle(hit),
      ),
    ));
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
