import 'app_localizations.dart';
import '../models/remote_agent.dart';

/// Extension methods for RemoteAgent localization
/// Use these when displaying model data in UI contexts
extension RemoteAgentL10n on RemoteAgent {
  /// Get localized status text
  String localizedStatusText(AppLocalizations l10n) {
    switch (status) {
      case AgentStatus.online:
        return l10n.status_online;
      case AgentStatus.offline:
        return l10n.status_offline;
      case AgentStatus.error:
        return l10n.status_error;
    }
  }

  /// Get localized protocol name
  String localizedProtocolName(AppLocalizations l10n) {
    switch (protocol) {
      case ProtocolType.acp:
        return l10n.status_protocolAcp;
      case ProtocolType.custom:
        return l10n.status_protocolCustom;
    }
  }
}

/// Extension for formatting timestamps with localization
extension TimestampL10n on int {
  /// Format a millisecond timestamp as a relative time string
  String toRelativeTime(AppLocalizations l10n) {
    final now = DateTime.now();
    final time = DateTime.fromMillisecondsSinceEpoch(this);
    final diff = now.difference(time);

    if (diff.inMinutes < 1) {
      return l10n.agentDetail_justNow;
    } else if (diff.inMinutes < 60) {
      return l10n.agentDetail_minutesAgo(diff.inMinutes);
    } else if (diff.inHours < 24) {
      return l10n.agentDetail_hoursAgo(diff.inHours);
    } else {
      return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
          '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
  }
}
