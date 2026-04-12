import '../models/scheduled_task.dart';

/// Abstract interface for executing a scheduled task.
///
/// Implementations must dispatch the task's instruction to the appropriate
/// target (an individual agent or a group channel).
abstract class TaskExecutor {
  Future<void> execute(ScheduledTask task);
}
