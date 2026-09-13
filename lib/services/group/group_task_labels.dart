import '../../l10n/app_localizations.dart';
import '../../models/group_task.dart';

String groupTaskMemberStatusLabel(AppLocalizations l10n, String status) {
  switch (status) {
    case GroupTaskMemberResult.statusDone:
      return l10n.group_taskStatusDone;
    case GroupTaskMemberResult.statusPending:
      return l10n.group_taskStatusPending;
    case GroupTaskMemberResult.statusFailed:
      return l10n.group_task_memberFailed;
    case GroupTaskMemberResult.statusStalled:
      return l10n.group_task_memberStalled;
    default:
      return status;
  }
}

String groupTaskStateLabel(AppLocalizations l10n, String status) {
  switch (status) {
    case GroupTask.statusClarifying:
      return l10n.group_taskStateClarifying;
    case GroupTask.statusPlanned:
      return l10n.group_taskStatePlanned;
    case GroupTask.statusExecuting:
      return l10n.group_taskStateExecuting;
    case GroupTask.statusSummarizing:
      return l10n.group_taskStateSummarizing;
    case GroupTask.statusDone:
      return l10n.group_taskStateDone;
    case GroupTask.statusPaused:
      return l10n.group_taskStatePaused;
    case GroupTask.statusFailed:
      return l10n.group_taskStateFailed;
    default:
      return status;
  }
}
