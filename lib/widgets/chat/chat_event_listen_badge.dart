import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/event/event_bus.dart';
import '../../theme/app_theme.dart';

const _kPanelWidth = 300.0;
const _kPanelMaxHeight = 280.0;
const Object _kTapGroup = 'chat_event_listen_panel';

/// AppBar 标题旁的「正在监听事件」徽标：有订阅或 wait 时显示图标和数量，
/// 悬停（桌面）或点击后在徽标下方展开监听列表。
class ChatEventListenBadge extends StatefulWidget {
  final List<String> agentIds;
  final Map<String, String> agentNames;

  const ChatEventListenBadge({
    super.key,
    required this.agentIds,
    this.agentNames = const {},
  });

  @override
  State<ChatEventListenBadge> createState() => _ChatEventListenBadgeState();
}

class _ChatEventListenBadgeState extends State<ChatEventListenBadge> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  Timer? _hideTimer;
  bool _overBadge = false;
  bool _overPanel = false;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  List<String> get _ids =>
      widget.agentIds.where((id) => id.isNotEmpty).toList(growable: false);

  void _showPanel() {
    _hideTimer?.cancel();
    if (!_portal.isShowing) _portal.show();
  }

  void _hidePanel() {
    _hideTimer?.cancel();
    _overBadge = false;
    _overPanel = false;
    if (_portal.isShowing) _portal.hide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 160), () {
      if (!mounted) return;
      if (!_overBadge && !_overPanel) _hidePanel();
    });
  }

  void _onBadgeTap() {
    if (_portal.isShowing && !_overBadge && !_overPanel) {
      _hidePanel();
    } else {
      _showPanel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ids = _ids;
    if (ids.isEmpty) return const SizedBox.shrink();

    return ListenableBuilder(
      listenable: EventBus.instance.listenListenable,
      builder: (context, _) {
        final entries = EventBus.instance.listenEntriesFor(ids);
        if (entries.isEmpty) {
          if (_portal.isShowing) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _hidePanel();
            });
          }
          return const SizedBox.shrink();
        }

        final l10n = AppLocalizations.of(context);
        final color = Theme.of(context).colorScheme.primary;
        return OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (overlayContext) {
            return _buildPanel(
              overlayContext,
              l10n: l10n,
              entries: EventBus.instance.listenEntriesFor(ids),
            );
          },
          child: CompositedTransformTarget(
            link: _link,
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: TapRegion(
                groupId: _kTapGroup,
                child: MouseRegion(
                  onEnter: (_) {
                    _overBadge = true;
                    _showPanel();
                  },
                  onExit: (_) {
                    _overBadge = false;
                    _scheduleHide();
                  },
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _onBadgeTap,
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.sensors, size: 13, color: color),
                            const SizedBox(width: 3),
                            Text(
                              '${entries.length}',
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.2,
                                color: color,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPanel(
    BuildContext overlayContext, {
    required AppLocalizations l10n,
    required List<AgentEventListenEntry> entries,
  }) {
    final showAgent = _ids.length > 1;
    final alignEnd = _shouldAlignEnd();
    return CompositedTransformFollower(
      link: _link,
      showWhenUnlinked: false,
      targetAnchor: alignEnd ? Alignment.bottomRight : Alignment.bottomLeft,
      followerAnchor: alignEnd ? Alignment.topRight : Alignment.topLeft,
      offset: const Offset(0, 6),
      child: TapRegion(
        groupId: _kTapGroup,
        onTapOutside: (_) => _hidePanel(),
        child: MouseRegion(
          onEnter: (_) {
            _overPanel = true;
            _hideTimer?.cancel();
          },
          onExit: (_) {
            _overPanel = false;
            _scheduleHide();
          },
          child: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: _kPanelWidth,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(overlayContext).colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.14),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                        child: Text(
                          '${l10n.chat_listeningEventsTitle} · ${entries.length}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: _kPanelMaxHeight - 40,
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.only(bottom: 8),
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            return Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(12, 4, 12, 6),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    entry.isWait
                                        ? Icons.hourglass_empty
                                        : Icons.sensors,
                                    size: 16,
                                    color: AppColors.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          entry.pattern,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontFamily: 'monospace',
                                            height: 1.25,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _subtitle(
                                            l10n,
                                            entry,
                                            showAgent: showAgent,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            height: 1.25,
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _shouldAlignEnd() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final pos = box.localToGlobal(Offset.zero);
    final width = MediaQuery.sizeOf(context).width;
    return pos.dx + _kPanelWidth > width - 12;
  }

  String _subtitle(
    AppLocalizations l10n,
    AgentEventListenEntry entry, {
    required bool showAgent,
  }) {
    final parts = <String>[];
    if (showAgent) {
      final name = widget.agentNames[entry.agentId];
      parts.add((name != null && name.isNotEmpty) ? name : entry.agentId);
    }
    if (entry.isWait) {
      parts.add(l10n.chat_eventListenKindWait);
      final correlation = entry.correlationId;
      if (correlation != null && correlation.isNotEmpty) {
        parts.add(correlation);
      }
    } else {
      parts.add(l10n.chat_eventListenKindSubscribe);
      final delivery = entry.delivery;
      if (delivery != null && delivery.isNotEmpty) {
        parts.add(delivery);
      }
    }
    return parts.join(' · ');
  }
}
