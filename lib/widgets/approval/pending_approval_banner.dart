import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/app_lifecycle_service.dart';
import '../../services/approval/pending_approval_hub.dart';
import '../../services/approval/pending_approval_item.dart';
import '../../services/chat_navigation_service.dart';

/// Persistent top banner while there are pending approvals outside the
/// currently viewed channel.
class PendingApprovalBanner extends StatefulWidget {
  final Widget child;

  const PendingApprovalBanner({super.key, required this.child});

  @override
  State<PendingApprovalBanner> createState() => _PendingApprovalBannerState();
}

class _PendingApprovalBannerState extends State<PendingApprovalBanner> {
  StreamSubscription<List<PendingApprovalItem>>? _hubSub;
  StreamSubscription<String?>? _channelSub;

  /// 挂在 ValueNotifier 上驱动局部 rebuild：banner 不在时直接返回
  /// 同一个 child 实例，Flutter 在该节点短路，app 根部的任何流都
  /// 不再连带整棵子树重建。
  final ValueNotifier<List<PendingApprovalItem>> _items =
      ValueNotifier<List<PendingApprovalItem>>(const []);

  /// activeChannel 变化不改 _items 内容，用独立 tick 通知可见集重算。
  final ValueNotifier<int> _visibleTick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _items.value = PendingApprovalHub.instance.all;
    _hubSub = PendingApprovalHub.instance.stream.listen((items) {
      _items.value = items;
    });
    _channelSub =
        AppLifecycleService().onActiveChannelChanged.listen((_) {
      // activeChannel 只影响可见集（不改 _items），用独立 tick 通知。
      _visibleTick.value++;
    });
  }

  @override
  void dispose() {
    _hubSub?.cancel();
    _channelSub?.cancel();
    _items.dispose();
    _visibleTick.dispose();
    super.dispose();
  }

  List<PendingApprovalItem> _visibleOf(List<PendingApprovalItem> items) {
    final active = AppLifecycleService().activeChannelId;
    if (active == null) return items;
    return items.where((i) => i.channelId != active).toList();
  }

  void _openReview(PendingApprovalItem item) {
    ChatNavigationService.instance.openChannel(
      channelId: item.channelId,
      messageId: item.messageId,
      agentId: item.agentId.isEmpty ? null : item.agentId,
      agentName: item.agentName,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _visibleTick,
      builder: (context, _, __) {
        return ValueListenableBuilder<List<PendingApprovalItem>>(
          valueListenable: _items,
          child: widget.child,
          builder: (context, items, child) {
            final visible = _visibleOf(items);
            if (visible.isEmpty) return child!;
            return _BannerBar(
              visible: visible,
              onOpenReview: _openReview,
              child: child!,
            );
          },
        );
      },
    );
  }
}

class _BannerBar extends StatelessWidget {
  final List<PendingApprovalItem> visible;
  final void Function(PendingApprovalItem) onOpenReview;
  final Widget child;

  const _BannerBar({
    required this.visible,
    required this.onOpenReview,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final latest = visible.first;
    final more = visible.length - 1;
    final kindLabel = latest.kind == PendingApprovalKind.plan
        ? l10n.approval_kindPlan
        : l10n.approval_kindAction;
    final title = l10n.approval_bannerTitle(latest.agentName, kindLabel);
    final subtitle = more > 0 ? l10n.approval_morePending(more) : null;
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Dismissible(
          key: ValueKey('approval_banner_${latest.id}'),
          direction: DismissDirection.horizontal,
          background: _DismissBackground(
            label: l10n.approval_dismissReminder,
            align: Alignment.centerLeft,
            color: colorScheme.surfaceContainerHighest,
            foreground: colorScheme.onSurfaceVariant,
            icon: Icons.close,
          ),
          secondaryBackground: _DismissBackground(
            label: l10n.approval_dismissReminder,
            align: Alignment.centerRight,
            color: colorScheme.surfaceContainerHighest,
            foreground: colorScheme.onSurfaceVariant,
            icon: Icons.close,
          ),
          confirmDismiss: (_) async {
            PendingApprovalHub.instance.dismiss(latest.id);
            return true;
          },
          child: Material(
            color: colorScheme.primaryContainer,
            elevation: 1,
            child: SafeArea(
              bottom: false,
              child: InkWell(
                onTap: () => onOpenReview(latest),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.rate_review_outlined,
                        size: 20,
                        color: colorScheme.onPrimaryContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onPrimaryContainer,
                              ),
                            ),
                            if (subtitle != null)
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colorScheme.onPrimaryContainer
                                      .withValues(alpha: 0.8),
                                ),
                              ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () => onOpenReview(latest),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          foregroundColor: colorScheme.onPrimaryContainer,
                          textStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: Text(l10n.approval_goReview),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _DismissBackground extends StatelessWidget {
  final String label;
  final Alignment align;
  final Color color;
  final Color foreground;
  final IconData icon;

  const _DismissBackground({
    required this.label,
    required this.align,
    required this.color,
    required this.foreground,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
          color: foreground,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          height: 1.2,
        );

    final trailing = align == Alignment.centerRight;

    return Material(
      color: color,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Align(
            alignment: align,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (trailing) ...[
                  Text(label, style: labelStyle),
                  const SizedBox(width: 6),
                  Icon(icon, color: foreground, size: 18),
                ] else ...[
                  Icon(icon, color: foreground, size: 18),
                  const SizedBox(width: 6),
                  Text(label, style: labelStyle),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
