import 'package:flutter/material.dart';
import '../../models/channel.dart';
import '../../models/remote_agent.dart';
import '../../services/she_service.dart';
import '../../utils/session_utils.dart';
import '../avatar_image.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';

/// AppBar title widget for DM (1-on-1) chat mode.
class ChatDMAppBarTitle extends StatelessWidget {
  final String? agentName;
  final String? agentAvatar;
  final bool isProcessing;
  final bool isCheckingHealth;
  final bool isAgentOnline;
  final String? currentChannelId;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onStopGenerating;

  /// 来源设备标签。非空时表示当前会话是某配对设备的入站会话，会在标题旁显示
  /// 一个「来自 设备名」徽标，方便多设备场景下区分。
  final String? sourceDeviceLabel;

  const ChatDMAppBarTitle({
    super.key,
    this.agentName,
    this.agentAvatar,
    required this.isProcessing,
    required this.isCheckingHealth,
    required this.isAgentOnline,
    this.currentChannelId,
    this.onAvatarTap,
    this.onStopGenerating,
    this.sourceDeviceLabel,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // She's functional/English name is "She"; display her localized name (e.g. 惜宝 in zh).
    final displayName =
        agentName == SheService.sheName ? l10n.she_name : agentName;

    return Row(
      children: [
        GestureDetector(
          onTap: onAvatarTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: agentAvatar != null && agentAvatar!.length > 2
                ? AvatarImage(
                    avatar: agentAvatar!,
                    size: 40,
                    borderRadius: 10,
                    fallback: Text(
                      displayName?.isNotEmpty == true
                          ? displayName![0]
                          : 'A',
                      style: const TextStyle(fontSize: 28),
                    ),
                  )
                : Text(
                    agentAvatar ??
                    (displayName?.isNotEmpty == true
                        ? displayName![0]
                        : 'A'),
                    style: const TextStyle(fontSize: 28),
                  ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      displayName ?? 'AI Agent',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (sourceDeviceLabel != null &&
                      sourceDeviceLabel!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .primaryColor
                              .withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.devices_outlined,
                              size: 12,
                              color: Theme.of(context).primaryColor,
                            ),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                sourceDeviceLabel!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context).primaryColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isProcessing) ...[
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      l10n.widget_typing,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).primaryColor,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    if (onStopGenerating != null) ...[
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: onStopGenerating,
                        child: Icon(
                          Icons.stop_circle,
                          size: 18,
                          color: Colors.red[400],
                        ),
                      ),
                    ],
                  ] else if (isCheckingHealth) ...[
                    Text(
                      l10n.status_connecting,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[400],
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ] else ...[
                    Text(
                      isAgentOnline
                          ? l10n.status_online
                          : l10n.status_offline,
                      style: TextStyle(
                        fontSize: 12,
                        color: isAgentOnline ? Colors.green : Colors.grey,
                      ),
                    ),
                  ],
                  if (currentChannelId != null) ...[
                    Text(
                      '  |  ',
                      style: TextStyle(fontSize: 10, color: Colors.grey[400]),
                    ),
                    Flexible(
                      child: Text(
                        SessionUtils.shortSessionId(currentChannelId!),
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey[500],
                          fontFamily: 'monospace',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// AppBar title widget for group chat mode.
class ChatGroupAppBarTitle extends StatelessWidget {
  final Channel? groupChannel;
  final List<RemoteAgent> groupAgents;
  final bool isProcessing;
  final Set<String> respondingAgentNames;
  final bool mentionOnlyMode;
  final String? currentChannelId;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onStopGenerating;

  const ChatGroupAppBarTitle({
    super.key,
    this.groupChannel,
    required this.groupAgents,
    required this.isProcessing,
    required this.respondingAgentNames,
    required this.mentionOnlyMode,
    this.currentChannelId,
    this.onAvatarTap,
    this.onStopGenerating,
  });

  @override
  Widget build(BuildContext context) {
    final groupName = groupChannel?.name ?? 'Group';
    final memberCount = groupAgents.length;

    return Row(
      children: [
        GestureDetector(
          onTap: onAvatarTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.group, size: 24, color: AppColors.primary),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                groupName,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (isProcessing)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (respondingAgentNames.isNotEmpty)
                      Flexible(
                        child: Text(
                          '${respondingAgentNames.join(', ')} typing...',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).primaryColor,
                            fontStyle: FontStyle.italic,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (onStopGenerating != null) ...[
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: onStopGenerating,
                        child: Icon(
                          Icons.stop_circle,
                          size: 18,
                          color: Colors.red[400],
                        ),
                      ),
                    ],
                  ],
                )
              else
                Row(
                  children: [
                    Text(
                      mentionOnlyMode
                          ? '$memberCount agents · @mention mode'
                          : groupChannel?.isAllMembersMentionMode == true
                              ? '$memberCount agents · all-mention mode'
                              : '$memberCount agents',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[500],
                      ),
                    ),
                    if (currentChannelId != null && groupChannel?.parentGroupId != null) ...[
                      Text(
                        '  |  ',
                        style: TextStyle(fontSize: 10, color: Colors.grey[400]),
                      ),
                      Flexible(
                        child: Text(
                          SessionUtils.shortSessionId(currentChannelId!, groupChannel: groupChannel),
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey[500],
                            fontFamily: 'monospace',
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}
