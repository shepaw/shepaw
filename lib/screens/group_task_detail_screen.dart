import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/group_task.dart';
import '../models/workflow_models.dart';
import 'storage_directory_opener.dart';
import '../services/group/group_task_display.dart';
import '../services/group/group_task_labels.dart';
import '../services/group/group_task_workflow_matcher.dart';
import '../services/store_open_service.dart';
import '../services/workflow/workflow_service.dart';
import '../storage/group_workspace_service.dart';
import '../widgets/workflow/workflow_list_tile.dart';
import 'workflow_detail_screen.dart';

/// One group task: structured fields first, compiled archive last.
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
  GroupTaskPlan? _plan;
  String? _planMd;
  GroupTaskResults? _results;
  String? _archive;
  List<String> _artifacts = const [];
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
    final plan = await ws.readTaskPlanJson(
      groupId: widget.groupId,
      orchestrationId: widget.orchestrationId,
    );
    final planMd = plan != null
        ? null
        : await ws.readTaskPlanMarkdown(
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
      _plan = plan;
      _planMd = planMd;
      _results = results;
      _archive = archive;
      _artifacts = GroupTaskDisplay.artifactUris(
        results: results,
        archive: archive,
      );
      _workflows = assignment.forTask(task.orchestrationId);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final task = _task;
    final heading = task == null
        ? l10n.group_task_detailTitle
        : GroupTaskDisplay.title(
            task.userGoal,
            fallback: l10n.group_task_detailTitle,
            maxChars: GroupTaskDisplay.detailTitleMaxChars,
          );
    return Scaffold(
      appBar: AppBar(
        title: Text(heading),
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
                      _goalHeader(context, l10n, task),
                      const SizedBox(height: 16),
                      _artifactsSection(l10n),
                      _requirementSection(context, l10n, task),
                      _planSection(context, l10n),
                      if (_results != null && _results!.members.isNotEmpty)
                        _resultsSection(l10n, _results!),
                      _workflowsSection(l10n),
                      _archiveSection(context, l10n),
                    ],
                  ),
                ),
    );
  }

  Widget _goalHeader(
    BuildContext context,
    AppLocalizations l10n,
    GroupTask task,
  ) {
    final short = GroupTaskDisplay.title(
      task.userGoal,
      fallback: task.orchestrationId,
      maxChars: GroupTaskDisplay.detailTitleMaxChars,
    );
    final raw = task.userGoal.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (raw.isNotEmpty && raw != short)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SelectableText(
              raw,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey.shade700,
                  ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: _StatusWrap(status: task.status),
        ),
      ],
    );
  }

  Widget _artifactsSection(AppLocalizations l10n) {
    if (_artifacts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.group_task_artifacts,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final uri in _artifacts)
                ActionChip(
                  avatar: Icon(
                    Icons.attach_file,
                    size: 16,
                    color: Colors.blue.shade700,
                  ),
                  label: Text(GroupTaskDisplay.artifactLabel(uri)),
                  onPressed: () => _openArtifact(uri),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _requirementSection(
    BuildContext context,
    AppLocalizations l10n,
    GroupTask task,
  ) {
    final text = _requirement?.trim() ?? '';
    if (text.isEmpty || text == task.userGoal.trim()) {
      return const SizedBox.shrink();
    }
    return _proseSection(context, l10n.group_task_requirement, text);
  }

  Widget _planSection(BuildContext context, AppLocalizations l10n) {
    final plan = _plan;
    if (plan != null) return _structuredPlan(context, l10n, plan);
    return _proseSection(context, l10n.group_task_plan, _planMd);
  }

  Widget _structuredPlan(
    BuildContext context,
    AppLocalizations l10n,
    GroupTaskPlan plan,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.group_task_plan,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          if (plan.acceptanceCriteria.isNotEmpty) ...[
            Text(
              l10n.group_task_acceptance,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            for (final c in plan.acceptanceCriteria)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text('• $c'),
              ),
            const SizedBox(height: 8),
          ],
          if (plan.constraints.isNotEmpty) ...[
            Text(
              l10n.group_task_constraints,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            for (final c in plan.constraints)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text('• $c'),
              ),
            const SizedBox(height: 8),
          ],
          for (final step in plan.steps)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              elevation: 0.5,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${l10n.group_task_planStep(step.step)} · '
                      '${step.agents.join('、')} · '
                      '${step.mode == 'sequential' ? l10n.group_task_planSequential : l10n.group_task_planConcurrent}',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(step.task),
                  ],
                ),
              ),
            ),
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
          const SizedBox(height: 8),
          for (final m in results.members)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              elevation: 0.5,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            m.agentName,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          [
                            groupTaskMemberStatusLabel(l10n, m.taskStatus),
                            if (m.round != null)
                              l10n.group_task_memberRound(m.round!),
                          ].join(' · '),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                    if (m.summary.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      SelectableText(m.summary),
                    ],
                    if (m.artifactUris.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final uri in m.artifactUris)
                            ActionChip(
                              avatar: const Icon(Icons.attach_file, size: 16),
                              label: Text(GroupTaskDisplay.artifactLabel(uri)),
                              onPressed: () => _openArtifact(uri),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _workflowsSection(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
    );
  }

  Widget _archiveSection(BuildContext context, AppLocalizations l10n) {
    final text = _archive?.trim() ?? '';
    if (text.isEmpty) return const SizedBox.shrink();
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Text(
          l10n.group_task_archive,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        subtitle: Text(
          l10n.group_task_archiveHint,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade700,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _proseSection(BuildContext context, String title, String? body) {
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

  Future<void> _openArtifact(String uri) async {
    registerStorageDirectoryOpener();
    await StoreOpenService.instance.openStoreUri(context, uri);
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
