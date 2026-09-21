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

/// 打开与 Agent 的会话并预填玉简任务。返回是否已派发。
Future<bool> dispatchJadeSlip(
  BuildContext context,
  JadeSlip slip, {
  String? preferredAgentId,
}) async {
  final l10n = AppLocalizations.of(context);
  final db = LocalDatabaseService();
  var agentId = (preferredAgentId ?? slip.assigneeAgentId).trim();
  String agentName = slip.assigneeAgentName;
  String? avatar;

  if (agentId.isEmpty) {
    final agents = await db.getAllRemoteAgents();
    if (!context.mounted) return false;
    final picked = await showDialog<(String, String, String?)>(
      context: context,
      builder: (ctx) {
        return SimpleDialog(
          title: Text(l10n.jadeSlip_pickAgent),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, (
                SheService.sheId,
                l10n.she_name,
                SheService.sheAvatar,
              )),
              child: Text(l10n.she_name),
            ),
            for (final a in agents)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, (a.id, a.name, a.avatar)),
                child: Text(a.name),
              ),
          ],
        );
      },
    );
    if (picked == null) return false;
    agentId = picked.$1;
    agentName = picked.$2;
    avatar = picked.$3;
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
  final channelId =
      await chatService.getLatestActiveChannelId(userId, agentId) ??
          chatService.generateChannelId(userId, agentId);

  getIt<ComposerDraftService>().setDraft(
    channelId,
    slip.toAgentPrompt(),
    agentId: agentId,
  );

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.jadeSlip_runHint)),
    );
  }
  await ChatNavigationService.instance.openChannel(
    channelId: channelId,
    agentId: agentId,
    agentName: agentName,
    agentAvatar: avatar,
  );
  return true;
}
