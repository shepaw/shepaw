import 'package:flutter/material.dart';

/// Compact unread count badge used in session lists and chat chrome.
class SessionUnreadBadge extends StatelessWidget {
  final int count;
  final bool overlayOnAvatar;

  const SessionUnreadBadge({
    super.key,
    required this.count,
    this.overlayOnAvatar = false,
  });

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();

    return Container(
      padding: count > 9
          ? const EdgeInsets.symmetric(horizontal: 4, vertical: 1)
          : EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(10),
        border: overlayOnAvatar
            ? Border.all(
                color: Theme.of(context).scaffoldBackgroundColor,
                width: 1.5,
              )
            : null,
      ),
      alignment: Alignment.center,
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Positions [SessionUnreadBadge] with its center on the host avatar's
/// top-right corner so the badge sits mostly outside the 40×40 avatar.
class AvatarUnreadBadgeOverlay extends StatelessWidget {
  final int count;

  const AvatarUnreadBadgeOverlay({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();

    return Positioned(
      right: 0,
      top: 0,
      child: FractionalTranslation(
        translation: const Offset(0.5, -0.5),
        child: SessionUnreadBadge(
          count: count,
          overlayOnAvatar: true,
        ),
      ),
    );
  }
}

/// Small red dot for icon buttons (e.g. session history entry).
class SessionUnreadDot extends StatelessWidget {
  const SessionUnreadDot({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: Colors.red,
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).colorScheme.surface,
          width: 1.5,
        ),
      ),
    );
  }
}
