import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/group_task.dart';
import '../models/workflow_models.dart';
import '../services/group/group_task_labels.dart';
import '../services/group/group_task_workflow_matcher.dart';
import '../services/workflow/workflow_service.dart';
import '../storage/group_workspace_service.dart';
import '../widgets/workflow/workflow_list_tile.dart';
import 'workflow_detail_screen.dart';

/// One group task: goal, artifacts, and any workflows used to finish it.
class GroupTaskDetailScreen extends StatefulWidget {
  final String groupId;
  final String orchestrationId;
  final String channelName;
  final WorkflowService workflowService;

  const GroupTaskDetailScreen({
    super.key,
    required this.groupId,
    required this.orchestrationId,
    required this.channelName,
    required this.workflowService,
  });

  @override
  State<GroupTaskDetailScreen> createState() => _GroupTaskDetailScreenState();
}

class _GroupTaskDetailScreenState extends State<GroupTaskDetailScreen> {
  GroupTask? _task;
  String? _requirement;
  String? _planMd;
  GroupTaskResults? _results;
  String? _archive;
  List<WorkflowExecution> _workflows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ws = GroupWorkspaceService.instance;
    final task = await ws.readTask(
      groupId: widget.groupId,
      orchestrationId: widget.orchestrationId,
    );
    if (task == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final requirement = await ws.readTaskRequirement(
      groupId: widget.groupId,
      orchestrationId: widget.orchestrationId,
    );
    final planMd = await ws.readTaskPlanMarkdown(
      groupId: widget.groupId,
      orchestrationId: widget.orchestrationId,
    );
    final results = await ws.readTaskResults(
      groupId: widget.groupId,
      orchestrationId: widget.orchestrationId,
    );
    final archive = await ws.readTaskArchive(
      groupId: widget.groupId,
      orchestrationId: widget.orchestrationId,
    );
    final channelWorkflows =
        await widget.workflowService.getWorkflowExecutions(task.sessionId);
    final assignment = GroupTaskWorkflowMatcher.assign(
      tasks: [task],
      workflows: channelWorkflows,
    );
    if (!mounted) return;
    setState(() {
      _task = task;
      _requirement = requirement;
      _planMd = planMd;
      _results = results;
      _archive = archive;
      _workflows = assignment.forTask(task.orchestrationId);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final task = _task;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.group_task_detailTitle),
        elevation: 1,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : task == null
              ? Center(child: Text(l10n.group_task_notFound))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [
                      Text(
                        task.userGoal.trim(),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _StatusWrap(status: task.status),
                      ),
                      const SizedBox(height: 16),
                      _section(
                        context,
                        l10n.group_task_requirement,
                        _requirement,
                      ),
                      _section(context, l10n.group_task_plan, _planMd),
                      if (_results != null && _results!.members.isNotEmpty)
                        _resultsSection(l10n, _results!),
                      _section(context, l10n.group_task_archive, _archive),
                      const SizedBox(height: 8),
                      Text(
                        l10n.group_task_workflows,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      if (_workflows.isEmpty)
                        Text(
                          l10n.group_task_noWorkflows,
                          style: TextStyle(color: Colors.grey.shade600),
                        )
                      else
                        for (final wf in _workflows)
                          WorkflowListTile(
                            execution: wf,
                            onTap: () => _openWorkflow(wf),
                          ),
                    ],
                  ),
                ),
    );
  }

  Widget _section(BuildContext context, String title, String? body) {
    final text = body?.trim() ?? '';
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          SelectableText(text, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }

  Widget _resultsSection(AppLocalizations l10n, GroupTaskResults results) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.group_task_results,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          for (final m in results.members)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '• ${m.agentName} · ${m.taskStatus}'
                '${m.summary.isEmpty ? '' : '\n  ${m.summary}'}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
        ],
      ),
    );
  }

  void _openWorkflow(WorkflowExecution execution) {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => WorkflowDetailScreen(
          workflowId: execution.id,
          workflowService: widget.workflowService,
        ),
      ),
    );
  }
}

class _StatusWrap extends StatelessWidget {
  final String status;
  const _StatusWrap({required this.status});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text(groupTaskStateLabel(l10n, status)),
    );
  }
}
