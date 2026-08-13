import 'package:flutter/material.dart';
import '../../models/channel.dart';
import '../../models/remote_agent.dart';
import '../../services/she_service.dart';
import '../../utils/layout_utils.dart';
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

  /// 正在从远端拉取该会话的聊天记录。为 true 时在 session id 旁显示「同步远端…」。
  final bool syncingRemote;

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
    this.syncingRemote = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDesktop = LayoutUtils.isDesktopLayout(context);
    // She's stored name is "She" until renamed; show localized default (惜宝)
    // only while it is still the functional default.
    final String? displayName = agentName == null
        ? null
        : SheService.resolveDisplayName(agentName, l10n.she_name);

    final metrics = _ChatAppBarMetrics.of(isDesktop);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _ChatAppBarAvatar(
          size: metrics.avatarSize,
          borderRadius: metrics.avatarRadius,
          onTap: onAvatarTap,
          backgroundColor: Colors.grey[200],
          statusColor: isAgentOnline ? const Color(0xFF34C759) : Colors.grey,
          child: agentAvatar != null && agentAvatar!.length > 2
              ? AvatarImage(
                  avatar: agentAvatar!,
                  size: metrics.avatarSize,
                  borderRadius: metrics.avatarRadius,
                  fallback: Text(
                    displayName?.isNotEmpty == true ? displayName![0] : 'A',
                    style: TextStyle(fontSize: metrics.avatarFallbackSize),
                  ),
                )
              : Text(
                  agentAvatar ??
                      (displayName?.isNotEmpty == true ? displayName![0] : 'A'),
                  style: TextStyle(fontSize: metrics.avatarFallbackSize),
                ),
        ),
        SizedBox(width: metrics.gap),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ChatAppBarNameRow(
                name: displayName ?? 'AI Agent',
                badge:
                    sourceDeviceLabel != null && sourceDeviceLabel!.isNotEmpty
                        ? _SourceDeviceBadge(label: sourceDeviceLabel!)
                        : null,
                badgeMaxWidth: metrics.badgeMaxWidth,
                style: metrics.nameStyle,
              ),
              SizedBox(height: metrics.subtitleGap),
              _ChatAppBarMetaRow(
                trailing: isProcessing && onStopGenerating != null
                    ? _StopGeneratingButton(onTap: onStopGenerating!)
                    : null,
                children: [
                  if (isProcessing)
                    _TypingMeta(
                      label: l10n.widget_typing,
                      color: Theme.of(context).primaryColor,
                    )
                  else if (isCheckingHealth)
                    _MetaText(
                      l10n.status_connecting,
                      color: Colors.grey[400],
                      italic: true,
                    )
                  else
                    _MetaText(
                      isAgentOnline ? l10n.status_online : l10n.status_offline,
                      color:
                          isAgentOnline ? const Color(0xFF34C759) : Colors.grey,
                    ),
                  if (currentChannelId != null)
                    _MetaText(
                      SessionUtils.shortSessionId(currentChannelId!),
                      color: Colors.grey[500],
                      monospace: true,
                    ),
                  if (syncingRemote)
                    _SyncingMeta(label: l10n.chat_syncingRemote),
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
    final isDesktop = LayoutUtils.isDesktopLayout(context);
    final metrics = _ChatAppBarMetrics.of(isDesktop);

    final membersLabel = mentionOnlyMode
        ? '$memberCount agents · @mention mode'
        : groupChannel?.isAllMembersMentionMode == true
            ? '$memberCount agents · all-mention mode'
            : '$memberCount agents';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _ChatAppBarAvatar(
          size: metrics.avatarSize,
          borderRadius: metrics.avatarRadius,
          onTap: onAvatarTap,
          backgroundColor: AppColors.primaryContainer,
          child: Icon(
            Icons.group,
            size: metrics.groupIconSize,
            color: AppColors.primary,
          ),
        ),
        SizedBox(width: metrics.gap),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ChatAppBarNameRow(
                name: groupName,
                badgeMaxWidth: metrics.badgeMaxWidth,
                style: metrics.nameStyle,
              ),
              SizedBox(height: metrics.subtitleGap),
              _ChatAppBarMetaRow(
                trailing: isProcessing && onStopGenerating != null
                    ? _StopGeneratingButton(onTap: onStopGenerating!)
                    : null,
                children: [
                  if (isProcessing)
                    _TypingMeta(
                      label: respondingAgentNames.isNotEmpty
                          ? '${respondingAgentNames.join(', ')} typing...'
                          : 'typing...',
                      color: Theme.of(context).primaryColor,
                    )
                  else
                    _MetaText(membersLabel, color: Colors.grey[500]),
                  if (!isProcessing &&
                      currentChannelId != null &&
                      groupChannel?.parentGroupId != null)
                    _MetaText(
                      SessionUtils.shortSessionId(
                        currentChannelId!,
                        groupChannel: groupChannel,
                      ),
                      color: Colors.grey[500],
                      monospace: true,
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChatAppBarMetrics {
  final double avatarSize;
  final double avatarRadius;
  final double avatarFallbackSize;
  final double groupIconSize;
  final double gap;
  final double subtitleGap;
  final double badgeMaxWidth;
  final TextStyle nameStyle;

  const _ChatAppBarMetrics({
    required this.avatarSize,
    required this.avatarRadius,
    required this.avatarFallbackSize,
    required this.groupIconSize,
    required this.gap,
    required this.subtitleGap,
    required this.badgeMaxWidth,
    required this.nameStyle,
  });

  factory _ChatAppBarMetrics.of(bool isDesktop) {
    if (isDesktop) {
      return const _ChatAppBarMetrics(
        avatarSize: 36,
        avatarRadius: 10,
        avatarFallbackSize: 18,
        groupIconSize: 20,
        gap: 12,
        subtitleGap: 2,
        badgeMaxWidth: 140,
        nameStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      );
    }
    return const _ChatAppBarMetrics(
      avatarSize: 32,
      avatarRadius: 8,
      avatarFallbackSize: 16,
      groupIconSize: 18,
      gap: 8,
      subtitleGap: 2,
      badgeMaxWidth: 96,
      nameStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.2,
      ),
    );
  }
}

class _ChatAppBarAvatar extends StatelessWidget {
  final double size;
  final double borderRadius;
  final VoidCallback? onTap;
  final Color? backgroundColor;
  final Color? statusColor;
  final Widget child;

  const _ChatAppBarAvatar({
    required this.size,
    required this.borderRadius,
    required this.child,
    this.onTap,
    this.backgroundColor,
    this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      child: child,
    );

    final withStatus = statusColor == null
        ? avatar
        : SizedBox(
            width: size,
            height: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                avatar,
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).appBarTheme.backgroundColor ??
                            Theme.of(context).colorScheme.surface,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );

    return GestureDetector(
      onTap: onTap,
      child: withStatus,
    );
  }
}

class _ChatAppBarNameRow extends StatelessWidget {
  final String name;
  final Widget? badge;
  final double badgeMaxWidth;
  final TextStyle style;

  const _ChatAppBarNameRow({
    required this.name,
    required this.style,
    required this.badgeMaxWidth,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        if (badge != null) ...[
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: badgeMaxWidth),
            child: badge!,
          ),
        ],
      ],
    );
  }
}

class _ChatAppBarMetaRow extends StatelessWidget {
  final List<Widget> children;
  final Widget? trailing;

  const _ChatAppBarMetaRow({
    required this.children,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Text(
                    ' · ',
                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                  ),
                Flexible(child: children[i]),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 6),
          trailing!,
        ],
      ],
    );
  }
}

class _MetaText extends StatelessWidget {
  final String text;
  final Color? color;
  final bool italic;
  final bool monospace;

  const _MetaText(
    this.text, {
    this.color,
    this.italic = false,
    this.monospace = false,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: monospace ? 11 : 12,
        height: 1.2,
        color: color,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        fontFamily: monospace ? 'monospace' : null,
      ),
    );
  }
}

class _TypingMeta extends StatelessWidget {
  final String label;
  final Color color;

  const _TypingMeta({
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: color,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.2,
              color: color,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      ],
    );
  }
}

class _SyncingMeta extends StatelessWidget {
  final String label;

  const _SyncingMeta({required this.label});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        SizedBox(
          width: 9,
          height: 9,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              height: 1.2,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

class _SourceDeviceBadge extends StatelessWidget {
  final String label;

  const _SourceDeviceBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).primaryColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.devices_outlined, size: 12, color: color),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StopGeneratingButton extends StatelessWidget {
  final VoidCallback onTap;

  const _StopGeneratingButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Icon(
        Icons.stop_circle,
        size: 18,
        color: Colors.red[400],
      ),
    );
  }
}
