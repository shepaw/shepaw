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
  List<PendingApprovalItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _items = PendingApprovalHub.instance.all;
    _hubSub = PendingApprovalHub.instance.stream.listen((items) {
      if (!mounted) return;
      setState(() => _items = items);
    });
    _channelSub =
        AppLifecycleService().onActiveChannelChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _hubSub?.cancel();
    _channelSub?.cancel();
    super.dispose();
  }

  List<PendingApprovalItem> get _visible {
    final active = AppLifecycleService().activeChannelId;
    if (active == null) return _items;
    return _items.where((i) => i.channelId != active).toList();
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
    final visible = _visible;
    if (visible.isEmpty) return widget.child;

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
                onTap: () => _openReview(latest),
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
                        onPressed: () => _openReview(latest),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          foregroundColor: colorScheme.onPrimaryContainer,
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
        Expanded(child: widget.child),
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
    return Container(
      color: color,
      alignment: align,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (align == Alignment.centerRight) ...[
            Text(
              label,
              style: TextStyle(
                color: foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Icon(icon, color: foreground, size: 20),
          if (align == Alignment.centerLeft) ...[
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
