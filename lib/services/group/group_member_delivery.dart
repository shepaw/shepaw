import 'dart:async';

import '../../models/remote_agent.dart';
import '../acp_agent_connection.dart';
import 'group_dispatch_parser.dart';
import 'group_member_stall.dart';
import 'group_member_task_context.dart';

/// Per-member delivery constraints and failure classification for group dispatch.
class GroupMemberDelivery {
  GroupMemberDelivery._();

  /// Machine-readable delivery hints for `group_context` (ACP / peer metadata).
  static Map<String, dynamic> deliveryContextFor(RemoteAgent agent) {
    final mode = agent.isPeerAgent
        ? 'hub_peer'
        : agent.isLocal
            ? 'app_local'
            : agent.usesHubCliExecute
                ? 'acp_shim'
                : 'acp';
    return {
      'mode': mode,
      'store_cli': agent.usesHubStoreCli
          ? 'shepaw_path'
          : agent.usesHubCliExecute
              ? 'hub_cli_execute'
              : agent.isLocal
                  ? 'shepaw_tool'
                  : 'unknown',
      'prefer_workspace_mount': agent.isPeerAgent || agent.usesHubCliExecute,
      'chat_only_accepted': true,
    };
  }

  /// Human-readable block injected into member turn content before 【你的任务】.
  static String buildDeliveryNote(RemoteAgent agent) {
    final lines = <String>['【宿主约束 · 交付方式】'];
    if (agent.isPeerAgent) {
      lines.add('- 宿主：Agent Hub 对端引擎（peer）；`store://runtime/…` 跨设备只读受限');
      lines.add('- 产物：优先写 **workspace 挂载目录** 或群 `shared/`（管理员可读）；');
      lines.add('  若 `shepaw store write` 不可用，直写 repo 根目录并给出绝对路径');
      lines.add('- 聊天条目化回答也算交付（管理员会读全文）');
    } else if (agent.usesHubStoreCli) {
      lines.add('- 宿主：Agent Hub 本机引擎；`shepaw store` 写 Hub device');
      lines.add('- 跨设备共享：另写一份到群 workspace `shared/` 或挂载路径');
    } else if (agent.usesHubCliExecute) {
      lines.add('- 宿主：外接 ACP（经 App shim）；store 经 `hub.cli.execute`');
      lines.add('- shim 缺失时：直写 workspace 挂载路径，勿反复重试 CLI');
    } else if (agent.isLocal) {
      lines.add('- 宿主：App 本地 LLM；`shepaw store write` 可用');
    } else {
      lines.add('- 宿主：外接 ACP；产物见作用域卡片');
    }
    return '${lines.join('\n')}\n';
  }

  /// Appended to recon (`intent=recon`) member briefs — time-boxed fact-finding.
  static String reconTimeBoxFooter() => '''

【摸底时间盒 · 系统默认】
- 只答 3 件事：链路主干、Top 5–8 可疑问题（带 文件:行号 或标「未验证·仅推测」）、最近验证时间与结论
- 先落盘再细化：产物写 workspace/shared 或 repo 挂载路径（防超时丢失）
- 聊天摘要 ≤40 行；禁止遍历全仓、禁止编造路径''';

  /// Classify member execution failure for results.json summaries.
  static String classifyFailure(Object error) {
    if (error is MemberStalledException) {
      return '超时未响应（>${error.timeout.inMinutes} 分钟）';
    }
    if (error is TimeoutException) {
      return 'ACP 任务超时（约 ${acpTaskTimeout.inMinutes} 分钟）';
    }
    final msg = error.toString();
    if (msg.contains('WritableIterable is closed') ||
        msg.contains('connection closed') ||
        msg.contains('Connection closed')) {
      return '连接中断（上游 ACP/WS 关闭）';
    }
    if (msg.contains('Agent busy')) return 'Agent 繁忙（status=busy）';
    if (msg.contains('acl_denied') || msg.contains('ACL')) {
      return 'store 权限拒绝';
    }
    if (msg.contains('ACP agent exited') || msg.contains('getOrCreateSession failed')) {
      return '上游 agent 进程退出';
    }
    final trimmed = msg.length > 120 ? '${msg.substring(0, 120)}…' : msg;
    return '执行失败：$trimmed';
  }

  /// Member-facing turn body for [group_dispatch] delegation.
  static String buildMemberDispatchContent({
    required RemoteAgent agent,
    required String memberBrief,
    required GroupMemberTaskContext taskContext,
    required String memoryNote,
    required List<DispatchStep> steps,
    required List<RemoteAgent> agents,
    required String peerResultsNote,
    required String loopEventNote,
    required int currentRound,
    bool stepIsRecon = false,
  }) {
    var brief = memberBrief.trim();
    if (stepIsRecon || DispatchStep.isReconOnly(steps)) {
      brief = '$brief${reconTimeBoxFooter()}';
    }
    return GroupDispatchParser.buildMemberTurnContent(
      memberBrief: brief,
      globalRequirement: taskContext.globalRequirement,
      memoryNote: memoryNote,
      taskPlanNote: taskContext.taskPlanNote,
      dispatchPlanNote: GroupDispatchParser.buildDispatchPlanNote(
        steps: steps,
        agents: agents,
      ),
      peerResultsNote: peerResultsNote,
      loopEventNote: loopEventNote,
      deliveryNote: buildDeliveryNote(agent),
      requirementUri: taskContext.requirementUri,
      isFollowUpRound: currentRound > 1,
    );
  }

  /// Shorter admin input on loop summarize rounds (avoids re-injecting the
  /// full user message + scope card every round).
  static String buildAdminLoopSummarizePrefix({
    required String userGoal,
    String? requirementUri,
    required int round,
  }) {
    final ref = (requirementUri != null && requirementUri.trim().isNotEmpty)
        ? '定稿需求 `$requirementUri`'
        : '用户原始需求见 shared/tasks/…/requirement.md';
    return '【本轮续编 · 第 $round 轮】$ref。\n'
        '用户目标摘要：${userGoal.trim().length > 200 ? '${userGoal.trim().substring(0, 200)}…' : userGoal.trim()}\n'
        '请根据下方成员回报与结构化结果综合回复；完整历史已在对话上下文中。';
  }
}
