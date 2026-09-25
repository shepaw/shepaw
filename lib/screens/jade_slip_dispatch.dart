import 'dart:async';

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
import '../services/logger_service.dart';
import '../services/remote_agent_service.dart';
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

/// 打开与 Agent 的会话并把玉简任务发出去。返回是否已派发。
///
/// 任务直接发送，不是预填草稿——用户已经在确认弹层点过一次了。只有连
/// Agent 行都取不到时才退回预填，见下面的 `target == null` 分支。
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

  if (slip.sourceChannelId.isEmpty) {
    await JadeSlipService.instance.update(
      slip.copyWith(sourceChannelId: targetChannelId),
    );
  }

  final prompt =
      slip.toAgentPrompt(focusItem: focusItem, onlyOpenItems: onlyOpenItems);
  final target = await getIt<RemoteAgentService>().getAgentById(agentId);

  if (target == null) {
    // 没有 Agent 行就发不出去（Agent 被删掉了？）。退回预填 + 跳转，
    // 至少别把用户已经确认的任务丢掉。
    getIt<ComposerDraftService>()
        .setDraft(targetChannelId, prompt, agentId: agentId);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.jadeSlip_sendFailed)),
      );
    }
  } else {
    // 确认即发送。sendMessageToAgent 要等 Agent 整个回合跑完才返回（可能
    // 几分钟），所以 fire-and-forget —— 与 dispatch_service 同一套写法。
    // 用户消息在任何协议发送之前就已落库，因此连不上 Agent 也不会丢任务。
    unawaited(
      chatService
          .sendMessageToAgent(
            content: prompt,
            agent: target,
            userId: userId,
            userName: LocalUserIdentity.displayName,
            channelId: targetChannelId,
          )
          .catchError((Object e, StackTrace st) {
        LoggerService().error(
          'jade slip dispatch send failed: ${target.name}',
          tag: 'JadeSlip',
          error: e,
          stackTrace: st,
        );
        return null;
      }),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.jadeSlip_runHint)),
      );
    }
  }

  await ChatNavigationService.instance.openChannel(
    channelId: targetChannelId,
    agentId: agentId,
    agentName: agentName,
    agentAvatar: avatar,
  );
  return true;
}
