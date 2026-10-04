import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';

/// 「稍后」按袋子 id 记在本机。
class OnboardingAgentCardStore {
  static const key = 'onboarding_agent_card_dismissed';

  static Future<bool> isDismissed(String pouchId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(key)?.contains(pouchId) ?? false;
  }

  static Future<void> dismiss(String pouchId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(key) ?? <String>[];
    if (current.contains(pouchId)) return;
    await prefs.setStringList(key, [...current, pouchId]);
  }
}

class OnboardingAgentCard extends StatelessWidget {
  const OnboardingAgentCard({
    super.key,
    required this.onAdd,
    required this.onLater,
  });

  final VoidCallback onAdd;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Material(
        color: scheme.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.onboarding_agentCardTitle,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(l10n.onboarding_agentCardBody),
              Row(
                children: [
                  FilledButton(
                    onPressed: onAdd,
                    child: Text(l10n.home_addAgentInstance),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: onLater,
                    child: Text(l10n.onboarding_agentCardLater),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
