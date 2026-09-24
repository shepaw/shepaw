import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/jade_slip.dart';
import '../service_locator.dart';
import '../services/chat_navigation_service.dart';
import '../services/chat_service.dart';
import '../services/composer_draft_service.dart';
import '../services/jade_slip_service.dart';
import '../services/local_database_service.dart';
import '../services/local_user_identity.dart';
import '../services/she_service.dart';
import 'jade_slip_agent_picker.dart';

/// 派发到哪条会话。
enum JadeSlipSessionTarget {
  /// 该 Agent 最近活跃的会话；没有就落到默认会话。
  current,

  /// 新开一条会话。
  fresh,

  /// 用户指定的会话（[dispatchJadeSlip] 的 `channelId`）。
  specific,
}

/// 打开与 Agent 的会话并预填玉简任务。返回是否已派发。
///
/// [focusItem] / [onlyOpenItems] 收窄交给 Agent 的清单范围，语义见
/// [JadeSlip.toAgentPrompt]；[sessionTarget] 决定落在哪条会话。
Future<bool> dispatchJadeSlip(
  BuildContext context,
  JadeSlip slip, {
  String? preferredAgentId,
  JadeSlipItem? focusItem,
  bool onlyOpenItems = false,
  JadeSlipSessionTarget sessionTarget = JadeSlipSessionTarget.current,
  String? channelId,
}) async {
  final l10n = AppLocalizations.of(context);
  final db = LocalDatabaseService();
  var agentId = (preferredAgentId ?? slip.assigneeAgentId).trim();
  String agentName = slip.assigneeAgentName;
  String? avatar;

  if (agentId.isEmpty) {
    final agents = await db.getAllRemoteAgents();
    if (!context.mounted) return false;
    final picked = await showJadeSlipAgentPicker(
      context,
      agents: agents,
    );
    if (picked == null || picked.id.isEmpty) return false;
    agentId = picked.id;
    agentName = picked.name;
    avatar = picked.avatar;
  } else if (agentId == SheService.sheId) {
    agentName = l10n.she_name;
    avatar = SheService.sheAvatar;
  } else {
    final agent = await db.getRemoteAgentById(agentId);
    agentName = agentName.isNotEmpty ? agentName : (agent?.name ?? agentId);
    avatar = agent?.avatar;
  }

  if (slip.assigneeAgentId != agentId) {
    await JadeSlipService.instance.update(slip.copyWith(
      assigneeAgentId: agentId,
      assigneeAgentName: agentName,
    ));
  }

  final chatService = getIt<ChatService>();
  const userId = LocalUserIdentity.id;
  final String targetChannelId;
  switch (sessionTarget) {
    case JadeSlipSessionTarget.fresh:
      targetChannelId = await chatService.createNewSession(
        userId: userId,
        userName: LocalUserIdentity.displayName,
        agentId: agentId,
        agentName: agentName,
      );
    case JadeSlipSessionTarget.specific:
      targetChannelId = channelId ??
          await chatService.getLatestActiveChannelId(userId, agentId) ??
          chatService.generateChannelId(userId, agentId);
    case JadeSlipSessionTarget.current:
      targetChannelId =
          await chatService.getLatestActiveChannelId(userId, agentId) ??
              chatService.generateChannelId(userId, agentId);
  }

  getIt<ComposerDraftService>().setDraft(
    targetChannelId,
    slip.toAgentPrompt(focusItem: focusItem, onlyOpenItems: onlyOpenItems),
    agentId: agentId,
  );

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.jadeSlip_runHint)),
    );
  }
  await ChatNavigationService.instance.openChannel(
    channelId: targetChannelId,
    agentId: agentId,
    agentName: agentName,
    agentAvatar: avatar,
  );
  return true;
}
