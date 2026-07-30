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

    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.primaryContainer,
          elevation: 1,
          child: SafeArea(
            bottom: false,
            child: InkWell(
              onTap: () {
                ChatNavigationService.instance.openChannel(
                  channelId: latest.channelId,
                  messageId: latest.messageId,
                  agentId: latest.agentId.isEmpty ? null : latest.agentId,
                  agentName: latest.agentName,
                );
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.rate_review_outlined,
                      size: 20,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
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
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer,
                            ),
                          ),
                          if (subtitle != null)
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer
                                    .withValues(alpha: 0.8),
                              ),
                            ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        ChatNavigationService.instance.openChannel(
                          channelId: latest.channelId,
                          messageId: latest.messageId,
                          agentId:
                              latest.agentId.isEmpty ? null : latest.agentId,
                          agentName: latest.agentName,
                        );
                      },
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor:
                            Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                      child: Text(l10n.approval_goReview),
                    ),
                  ],
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
