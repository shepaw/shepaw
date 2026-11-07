import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/folded_sessions.dart';
import '../../peer/services/flow_session_open.dart';
import '../../peer/services/hub_flow.dart';
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

/// A10-8 测试缝：注入「从运行树解析节点 agent」的结果，避免测试连真主机。
@visibleForTesting
Future<String?> Function({
  required String peerId,
  required String runId,
  required String sessionId,
})? debugResolveFlowSearchHitAgent;

/// 搜索命中没带 `agent_id` 时，按 A8-3 的口径重拉一次运行树，找同 session
/// 的节点拿 agent。拿不到就返回空，由调用方延后 / 提示，绝不以空 agent 建壳。
Future<String?> _resolveFlowSearchHitAgent({
  required String peerId,
  required String runId,
  required String sessionId,
}) async {
  final hook = debugResolveFlowSearchHitAgent;
  if (hook != null) {
    try {
      return (await hook(
        peerId: peerId,
        runId: runId,
        sessionId: sessionId,
      ))
          ?.trim();
    } catch (_) {
      return null;
    }
  }
  try {
    final run = await HubFlow().run(peerId, runId);
    if (run == null) return null;
    for (final root in run.tree) {
      final node = root.find((candidate) =>
          candidate.sessionId == sessionId &&
          (candidate.agentId?.trim().isNotEmpty ?? false));
      final agentId = node?.agentId?.trim() ?? '';
      if (agentId.isNotEmpty) return agentId;
    }
  } catch (_) {
    // 主机没应答不该让这次点击抛异常；留给「正在准备会话」文案。
  }
  return null;
}

/// 命中里主机没给 agent：先提示再重拉，拿到 agent 才打开会话；仍拿不到就
/// 不打开空壳频道（用户再点时可能已经同步好了）。
Future<void> _openFlowSearchHitAfterAgent({
  required BuildContext context,
  required String peerId,
  required SessionSearchHit hit,
  required String sessionId,
}) async {
  final l10n = AppLocalizations.of(context);
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(l10n.flow_sessionPreparing)),
  );
  final agentId = await _resolveFlowSearchHitAgent(
    peerId: peerId,
    runId: hit.origin.runId,
    sessionId: sessionId,
  );
  if (agentId == null || agentId.isEmpty || !context.mounted) return;
  await openFlowNodeSession(
    peerId: peerId,
    sessionId: sessionId,
    remoteAgentId: agentId,
    title: _hitTitle(hit),
  );
}

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
///
/// 弹层结束后才用外层的 [context] 跳转：弹层期间那一行可能被卸载（列表刷新、
/// 切频道），此时 `Navigator.of(context)` 会直接抛异常。
Future<void> showFlowRunActions(
  BuildContext context, {
  required String peerId,
  required String runId,
  required String title,
}) async {
  final viewRun = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.account_tree_outlined),
            title: Text(AppLocalizations.of(sheetContext).flow_viewRun),
            onTap: () => Navigator.pop(sheetContext, true),
          ),
        ],
      ),
    ),
  );
  if (viewRun != true || !context.mounted) return;
  pushFlowRunScreen(context, peerId: peerId, runId: runId, title: title);
}

/// 打开一条命中：私聊本来就在平铺列表里（调用方自己切），工作流节点优先打开
/// 它的 agent 会话（和私聊一样能继续聊 / 停止），群聊进群聊视角，其余走主机的
/// 会话历史。没有真会话 id 的旧条目仍退回运行视图。
/// flow 命中缺 agent 时先解析 / 重拉，拿不到就显示「正在准备会话」，不会
/// 打开一条没有成员的空壳频道（A10-8）。
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
      // A10-8：`agent_id` 可能缺失（SessionSearchHit.fromJson 默认 ''）。
      // flow 分支的 origin.from_agent 就是该节点的 agent；仍拿不到就重拉
      // 运行树，绝不以空 agentId 建频道 / 发无目标的会话。
      final candidates = [hit.agentId.trim(), origin.fromAgent.trim()];
      final agentId = candidates.firstWhere(
        (value) => value.isNotEmpty,
        orElse: () => '',
      );
      if (agentId.isNotEmpty) {
        unawaited(openFlowNodeSession(
          peerId: peerId,
          sessionId: sessionId,
          remoteAgentId: agentId,
          title: _hitTitle(hit),
        ));
      } else {
        unawaited(_openFlowSearchHitAfterAgent(
          context: context,
          peerId: peerId,
          hit: hit,
          sessionId: sessionId,
        ));
      }
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
