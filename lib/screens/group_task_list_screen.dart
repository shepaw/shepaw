import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/group_task.dart';
import '../models/workflow_models.dart';
import '../services/group/group_task_labels.dart';
import '../services/group/group_task_workflow_matcher.dart';
import '../services/local_database_service.dart';
import '../services/workflow/workflow_service.dart';
import '../storage/group_workspace_service.dart';
import '../widgets/workflow/workflow_list_tile.dart';
import 'group_task_detail_screen.dart';
import 'workflow_detail_screen.dart';

/// Group task list. Workflows are a way to finish a task, not a top-level entry.
class GroupTaskListScreen extends StatefulWidget {
  final String groupId;
  final String channelId;
  final String channelName;
  final VoidCallback? onBack;

  const GroupTaskListScreen({
    super.key,
    required this.groupId,
    required this.channelId,
    required this.channelName,
    this.onBack,
  });

  @override
  State<GroupTaskListScreen> createState() => _GroupTaskListScreenState();
}

class _GroupTaskListScreenState extends State<GroupTaskListScreen> {
  late final WorkflowService _workflowService;
  List<GroupTask> _tasks = [];
  GroupTaskWorkflowAssignment _assignment = const GroupTaskWorkflowAssignment(
    byOrchestrationId: {},
    orphans: [],
  );
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _workflowService = WorkflowService(db: LocalDatabaseService());
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final index =
        await GroupWorkspaceService.instance.readTaskIndex(widget.groupId);
    final tasks = <GroupTask>[];
    for (final entry in index.recent) {
      final task = await GroupWorkspaceService.instance.readTask(
        groupId: widget.groupId,
        orchestrationId: entry.orchestrationId,
      );
      if (task != null) {
        tasks.add(task);
      } else {
        tasks.add(GroupTask(
          orchestrationId: entry.orchestrationId,
          sessionId: widget.channelId,
          status: entry.status,
          userGoal: entry.title,
          finishedAt: entry.finishedAt,
        ));
      }
    }
    tasks.sort((a, b) {
      if (a.isTerminal != b.isTerminal) return a.isTerminal ? 1 : -1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    final workflows =
        await _workflowService.getWorkflowExecutions(widget.channelId);
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _assignment = GroupTaskWorkflowMatcher.assign(
        tasks: tasks,
        workflows: workflows,
      );
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBack ?? () => Navigator.pop(context),
        ),
        title: Text(l10n.group_task_listTitle(widget.channelName)),
        elevation: 1,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _tasks.isEmpty && _assignment.orphans.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.5,
                          child: _emptyState(l10n),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      children: [
                        for (final task in _tasks)
                          _TaskTile(
                            task: task,
                            workflowCount:
                                _assignment.forTask(task.orchestrationId).length,
                            onTap: () => _openDetail(task),
                          ),
                        if (_assignment.orphans.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            child: Text(
                              l10n.group_task_orphanWorkflows,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          for (final wf in _assignment.orphans)
                            WorkflowListTile(
                              execution: wf,
                              onTap: () => _openWorkflow(wf),
                            ),
                        ],
                      ],
                    ),
            ),
    );
  }

  Widget _emptyState(AppLocalizations l10n) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.assignment_outlined,
              size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            l10n.group_task_empty,
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey.shade500,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.group_task_emptyHint,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Future<void> _openDetail(GroupTask task) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => GroupTaskDetailScreen(
          groupId: widget.groupId,
          orchestrationId: task.orchestrationId,
          channelName: widget.channelName,
          workflowService: _workflowService,
        ),
      ),
    );
    if (mounted) _load();
  }

  void _openWorkflow(WorkflowExecution execution) {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => WorkflowDetailScreen(
          workflowId: execution.id,
          workflowService: _workflowService,
        ),
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  final GroupTask task;
  final int workflowCount;
  final VoidCallback onTap;

  const _TaskTile({
    required this.task,
    required this.workflowCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final active = !task.isTerminal;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: active ? 2 : 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: active
            ? BorderSide(color: Colors.blue.shade200, width: 1.5)
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      task.userGoal.trim().isEmpty
                          ? task.orchestrationId
                          : task.userGoal.trim(),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _TaskStatusChip(status: task.status),
                ],
              ),
              if (workflowCount > 0) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.account_tree_outlined,
                        size: 14, color: Colors.grey.shade600),
                    const SizedBox(width: 4),
                    Text(
                      l10n.group_task_workflowCount(workflowCount),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskStatusChip extends StatelessWidget {
  final String status;
  const _TaskStatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (bg, fg) = _colors(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        groupTaskStateLabel(l10n, status),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }

  static (Color, Color) _colors(String status) {
    switch (status) {
      case GroupTask.statusExecuting:
      case GroupTask.statusSummarizing:
        return (Colors.blue.shade100, Colors.blue.shade800);
      case GroupTask.statusClarifying:
      case GroupTask.statusPlanned:
        return (Colors.orange.shade100, Colors.orange.shade800);
      case GroupTask.statusDone:
        return (Colors.green.shade100, Colors.green.shade800);
      case GroupTask.statusFailed:
        return (Colors.red.shade100, Colors.red.shade800);
      case GroupTask.statusPaused:
        return (Colors.grey.shade200, Colors.grey.shade700);
      default:
        return (Colors.grey.shade200, Colors.grey.shade700);
    }
  }
}
