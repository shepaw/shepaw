/// Admin history window: full channel vs current task only.
enum GroupAdminHistoryScope {
  /// Full channel transcript (legacy).
  channel,

  /// Only messages belonging to the current `orchestrationId`.
  task,
}

/// Feature flags for incremental group task orchestration rollout.
///
/// Defaults favor the new structured-task path; set [structuredTasks] to
/// `false` to disable shared/tasks/ writes without reverting code.
class GroupOrchestrationFeatures {
  GroupOrchestrationFeatures._();

  /// Create `shared/tasks/<orchestrationId>/` on each user-triggered编排.
  static bool structuredTasks = true;

  /// Require `group_plan_publish` before `group_dispatch` (local admin only).
  static bool requirePublishedPlan = true;

  /// Admin LLM history: `task` excludes prior-task agent chatter (PR-5).
  static GroupAdminHistoryScope adminHistoryScope =
      GroupAdminHistoryScope.task;

  /// Whether admin turns filter history to the active task.
  static bool get useTaskScopedAdminHistory =>
      structuredTasks && adminHistoryScope == GroupAdminHistoryScope.task;

  /// Persist member outcomes to `results.json` and inject peer summaries (PR-7).
  static bool structuredResults = true;

  /// Wake admin mid-loop when a member pending reason contains `[NEED_ADMIN]`.
  static bool pendingAdminWake = true;

  /// Timeout → `stalled` first; repeated stalls escalate to `failed` (PR-9).
  static bool stalledTimeout = true;

  /// Admin mid-loop follow-up rounds allowed per stall before auto-fail.
  static int memberStallGraceRounds = 1;

  /// Consecutive stall events before marking a member failed.
  static int maxStallsBeforeFail = 2;
}
