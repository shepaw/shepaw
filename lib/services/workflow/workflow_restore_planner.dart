import '../../models/workflow_models.dart';

/// What [_restoreWorkflowContext] should do after loading step state.
enum WorkflowRestoreActionKind {
  /// Nothing to do for execution (already terminal / no pending work).
  none,

  /// An in-process ChatService loop is alive — only reattach UI callbacks.
  reattachOnly,

  /// All steps succeeded — mark workflow completed.
  finalizeSucceeded,

  /// All steps terminal with failures — mark workflow failed.
  finalizeFailed,

  /// Orphan `running` steps with no pending left — heal then finalize.
  healOrphansThenFinalize,

  /// Orphan `running` steps remain pending work — heal then resume.
  healOrphansThenResume,

  /// Interrupted execution with pending steps — resume the loop.
  resumePending,
}

/// Immutable restore decision derived from workflow snapshots.
class WorkflowRestorePlan {
  final WorkflowRestoreActionKind kind;
  final List<WorkflowStepExecution> stuckRunning;
  final int pendingCount;
  final int completedSteps;
  final int totalSteps;
  final int failedSteps;

  const WorkflowRestorePlan({
    required this.kind,
    this.stuckRunning = const [],
    this.pendingCount = 0,
    this.completedSteps = 0,
    this.totalSteps = 0,
    this.failedSteps = 0,
  });

  bool get shouldResume =>
      kind == WorkflowRestoreActionKind.resumePending ||
      kind == WorkflowRestoreActionKind.healOrphansThenResume;

  bool get shouldHealOrphans =>
      kind == WorkflowRestoreActionKind.healOrphansThenFinalize ||
      kind == WorkflowRestoreActionKind.healOrphansThenResume;
}

/// Pure planner for workflow channel-restore / resume decisions.
class WorkflowRestorePlanner {
  WorkflowRestorePlanner._();

  /// Plan execution restore after pending-approval UI has been handled.
  ///
  /// [isExecutingInProcess] = ChatService already owns a live loop.
  /// [hasLocalCancelToken] = this controller already started a loop locally.
  static WorkflowRestorePlan plan({
    required WorkflowExecution? active,
    required bool isExecutingInProcess,
    required bool hasLocalCancelToken,
    WorkflowExecution? withSteps,
  }) {
    if (active == null || active.status != WorkflowStatus.running) {
      return const WorkflowRestorePlan(kind: WorkflowRestoreActionKind.none);
    }

    if (isExecutingInProcess) {
      return const WorkflowRestorePlan(
        kind: WorkflowRestoreActionKind.reattachOnly,
      );
    }

    final snapshot = withSteps;
    if (snapshot == null || snapshot.status != WorkflowStatus.running) {
      return const WorkflowRestorePlan(kind: WorkflowRestoreActionKind.none);
    }

    if (snapshot.allStepsSucceeded) {
      return WorkflowRestorePlan(
        kind: WorkflowRestoreActionKind.finalizeSucceeded,
        completedSteps: snapshot.completedSteps,
        totalSteps: snapshot.totalSteps,
      );
    }
    if (snapshot.allStepsTerminal) {
      return WorkflowRestorePlan(
        kind: WorkflowRestoreActionKind.finalizeFailed,
        completedSteps: snapshot.completedSteps,
        totalSteps: snapshot.totalSteps,
        failedSteps: snapshot.failedSteps,
      );
    }

    final stuckRunning = snapshot.steps
        .where((s) => s.status == StepExecutionStatus.running)
        .toList();
    final pendingCount = snapshot.steps
        .where((s) => s.status == StepExecutionStatus.pending)
        .length;

    if (stuckRunning.isNotEmpty) {
      if (pendingCount == 0) {
        return WorkflowRestorePlan(
          kind: WorkflowRestoreActionKind.healOrphansThenFinalize,
          stuckRunning: stuckRunning,
          pendingCount: pendingCount,
          completedSteps: snapshot.completedSteps,
          totalSteps: snapshot.totalSteps,
          failedSteps: snapshot.failedSteps,
        );
      }
      return WorkflowRestorePlan(
        kind: WorkflowRestoreActionKind.healOrphansThenResume,
        stuckRunning: stuckRunning,
        pendingCount: pendingCount,
        completedSteps: snapshot.completedSteps,
        totalSteps: snapshot.totalSteps,
        failedSteps: snapshot.failedSteps,
      );
    }

    if (!hasLocalCancelToken && pendingCount > 0) {
      return WorkflowRestorePlan(
        kind: WorkflowRestoreActionKind.resumePending,
        pendingCount: pendingCount,
        completedSteps: snapshot.completedSteps,
        totalSteps: snapshot.totalSteps,
        failedSteps: snapshot.failedSteps,
      );
    }

    return WorkflowRestorePlan(
      kind: WorkflowRestoreActionKind.none,
      pendingCount: pendingCount,
      completedSteps: snapshot.completedSteps,
      totalSteps: snapshot.totalSteps,
      failedSteps: snapshot.failedSteps,
    );
  }
}
