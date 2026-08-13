import 'package:flutter/material.dart';

import '../services/update_service.dart';
import 'chat/session_unread_badge.dart';

/// Wraps a settings icon and shows a red dot when an update is available.
class SettingsUpdateBadge extends StatelessWidget {
  final Widget child;

  const SettingsUpdateBadge({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: UpdateService(),
      builder: (context, _) {
        if (!UpdateService().showSettingsRedDot) return child;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            child,
            const Positioned(
              right: 0,
              top: 0,
              child: SessionUnreadDot(),
            ),
          ],
        );
      },
    );
  }
}

/// Small "NEW" label shown next to the check-for-updates row.
class UpdateNewBadge extends StatelessWidget {
  final String label;

  const UpdateNewBadge({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colorScheme.error,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: colorScheme.onError,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          height: 1.1,
        ),
      ),
    );
  }
}
