import 'package:flutter/material.dart';

import '../helpers/cron_parser.dart';
import '../../l10n/app_localizations.dart';
import '../models/scheduled_task.dart';
import '../../models/remote_agent.dart';
import '../../services/logger_service.dart';
import '../../services/local_database_service.dart';
import '../services/scheduled_task_service.dart';
import '../../services/remote_agent_service.dart';
import '../../service_locator.dart' show getIt;

/// Screen for managing scheduled tasks.
class ScheduledTasksManagementScreen extends StatefulWidget {
  final VoidCallback? onCreateTask;
  final Function(ScheduledTask task)? onEditTask;

  const ScheduledTasksManagementScreen({
    Key? key,
    this.onCreateTask,
    this.onEditTask,
  }) : super(key: key);

  @override
  State<ScheduledTasksManagementScreen> createState() =>
      _ScheduledTasksManagementScreenState();
}

class _ScheduledTasksManagementScreenState
    extends State<ScheduledTasksManagementScreen> {
  final ScheduledTaskService _taskService = ScheduledTaskService();
  final LocalDatabaseService _db = LocalDatabaseService();
  late Future<List<ScheduledTask>> _tasksFuture;
  late Future<List<RemoteAgent>> _agentsFuture;
  String? _selectedAgentFilter;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _tasksFuture = _loadTasks();
      _agentsFuture = _loadAgents();
    });
  }

  Future<List<ScheduledTask>> _loadTasks() async {
    try {
      if (_selectedAgentFilter != null) {
        return await _taskService.listTasksForAgent(_selectedAgentFilter!);
      }
      return await _db.listScheduledTasks();
    } catch (e) {
      LoggerService().error('Failed to load tasks', error: e);
      return [];
    }
  }

  Future<List<RemoteAgent>> _loadAgents() async {
    try {
      final agentService = getIt<RemoteAgentService>();
      return await agentService.getAllAgents();
    } catch (e) {
      LoggerService().error('Failed to load agents', error: e);
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return const SizedBox.shrink();

    return FutureBuilder<List<RemoteAgent>>(
      future: _agentsFuture,
      builder: (context, agentsSnapshot) {
        final agents = agentsSnapshot.data ?? [];

        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.scheduledTasks_title),
          ),
          body: Column(
            children: [
              if (agents.isNotEmpty)
                _buildAgentFilterBar(agents, l10n),
              Expanded(
                child: FutureBuilder<List<ScheduledTask>>(
                  future: _tasksFuture,
                  builder: (context, tasksSnapshot) {
                    if (!tasksSnapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final tasks = tasksSnapshot.data ?? [];

                    if (tasks.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.schedule, size: 64, color: Colors.grey[400]),
                            const SizedBox(height: 16),
                            Text(l10n.scheduledTasks_noTasks, style: const TextStyle(fontSize: 18)),
                            const SizedBox(height: 8),
                            Text(l10n.scheduledTasks_noTasksHint, style: TextStyle(color: Colors.grey[600])),
                          ],
                        ),
                      );
                    }

                    return ListView.builder(
                      itemCount: tasks.length,
                      itemBuilder: (context, index) {
                        final task = tasks[index];
                        return _buildTaskCard(context, task, agents, l10n);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () => widget.onCreateTask?.call(),
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }

  Widget _buildAgentFilterBar(List<RemoteAgent> agents, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              l10n.scheduledTasks_filterByAgent,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                letterSpacing: 0.5,
              ),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              children: [
                // "All" chip
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    selected: _selectedAgentFilter == null,
                    label: Text(l10n.scheduledTasks_filterAll),
                    avatar: _selectedAgentFilter == null
                        ? null
                        : const Icon(Icons.people_outline, size: 16),
                    onSelected: (_) {
                      setState(() => _selectedAgentFilter = null);
                      _refresh();
                    },
                    showCheckmark: true,
                    selectedColor: colorScheme.primaryContainer,
                    labelStyle: TextStyle(
                      color: _selectedAgentFilter == null
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurfaceVariant,
                      fontWeight: _selectedAgentFilter == null
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                    side: BorderSide(
                      color: _selectedAgentFilter == null
                          ? colorScheme.primary
                          : colorScheme.outlineVariant,
                      width: _selectedAgentFilter == null ? 1.5 : 1,
                    ),
                  ),
                ),
                // One chip per agent
                ...agents.map((agent) {
                  final isSelected = _selectedAgentFilter == agent.id;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      selected: isSelected,
                      avatar: CircleAvatar(
                        radius: 10,
                        backgroundColor: isSelected
                            ? colorScheme.primary
                            : colorScheme.surfaceContainerHighest,
                        child: Text(
                          agent.name.isNotEmpty
                              ? agent.name[0].toUpperCase()
                              : '?',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: isSelected
                                ? colorScheme.onPrimary
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      label: Text(agent.name),
                      onSelected: (_) {
                        setState(() => _selectedAgentFilter =
                            isSelected ? null : agent.id);
                        _refresh();
                      },
                      showCheckmark: false,
                      selectedColor: colorScheme.primaryContainer,
                      labelStyle: TextStyle(
                        color: isSelected
                            ? colorScheme.onPrimaryContainer
                            : colorScheme.onSurfaceVariant,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                      side: BorderSide(
                        color: isSelected
                            ? colorScheme.primary
                            : colorScheme.outlineVariant,
                        width: isSelected ? 1.5 : 1,
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskCard(BuildContext context, ScheduledTask task, List<RemoteAgent> agents, AppLocalizations l10n) {
    final agent = task.agentId != null
        ? agents.firstWhere(
            (a) => a.id == task.agentId,
            orElse: () => RemoteAgent(
              id: task.agentId!,
              name: 'Unknown Agent',
              token: '',
              endpoint: '',
              protocol: ProtocolType.acp,
              connectionType: ConnectionType.websocket,
              createdAt: DateTime.now().millisecondsSinceEpoch,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          )
        : null;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(task.description, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      if (task.executionTarget == ScheduledTask.targetGroup)
                        Text('Group task · ${task.agentIds.length} agents', style: TextStyle(color: Colors.grey[600]))
                      else
                        Text('Agent: ${agent?.name ?? 'Unknown'}', style: TextStyle(color: Colors.grey[600])),
                    ],
                  ),
                ),
                _buildStatusBadge(task.status, l10n),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _getScheduleDescription(task.schedulePattern, l10n),
              style: TextStyle(color: Colors.grey[700], fontSize: 13),
            ),
            const SizedBox(height: 8),
            Text(
              '${l10n.scheduledTasks_executionCount(task.executionCount.toString())} | ${l10n.scheduledTasks_failureCount(task.failureCount.toString())}',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
            if (task.lastError != null && task.lastError!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                child: Text(
                  l10n.scheduledTasks_lastError(task.lastError!),
                  style: TextStyle(color: Colors.red[700], fontSize: 12),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _toggleTaskStatus(task),
                  child: Text(
                    task.status == ScheduledTask.statusActive ? l10n.scheduledTasks_pauseTask : l10n.scheduledTasks_activateTask,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => _executeTaskNow(context, task, l10n),
                  child: Text(l10n.scheduledTasks_executeNow),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => widget.onEditTask?.call(task),
                  child: Text(l10n.common_edit),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => _confirmDeleteTask(context, task, l10n),
                  child: Text(l10n.common_delete, style: const TextStyle(color: Colors.red)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(String status, AppLocalizations l10n) {
    final label = _getStatusLabel(status, l10n);
    final color = _getStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: color.withOpacity(0.2), border: Border.all(color: color), borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
    );
  }

  Future<void> _toggleTaskStatus(ScheduledTask task) async {
    try {
      if (task.status == ScheduledTask.statusActive) {
        await _taskService.pauseScheduledTask(task.id);
      } else if (task.status == ScheduledTask.statusPaused) {
        await _taskService.activateScheduledTask(task.id);
      }
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _executeTaskNow(BuildContext context, ScheduledTask task, AppLocalizations l10n) async {
    // Fire-and-forget: don't await the full agent execution, only the dispatch.
    _taskService.executeTaskNow(task.id).catchError((e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.scheduledTasks_executeNowSuccess)));
    }
  }

  Future<void> _confirmDeleteTask(BuildContext context, ScheduledTask task, AppLocalizations l10n) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.scheduledTasks_confirmDelete),
        content: Text(l10n.scheduledTasks_confirmDeleteMsg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.common_cancel)),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.scheduledTasks_deleteTask, style: const TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _taskService.deleteScheduledTask(task.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.scheduledTasks_deleteSuccess)));
          _refresh();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    }
  }

  String _getScheduleDescription(String pattern, AppLocalizations l10n) {
    // One-time task: pattern is a raw millisecond timestamp.
    final ms = int.tryParse(pattern);
    if (ms != null && ms > 0) {
      final dt = DateTime.fromMillisecondsSinceEpoch(ms);
      return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}'
          ' ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }

    // Interval task: ISO 8601 duration (PT5M, PT1H, P1D …).
    if (pattern.toUpperCase().startsWith('P')) {
      final duration = CronParser.parseIsoDuration(pattern);
      if (duration != null) {
        return 'Every ${CronParser.describeDuration(pattern)}';
      }
    }

    // Cron expression.
    return CronParser.describeCron(pattern);
  }

  String _getStatusLabel(String status, AppLocalizations l10n) {
    switch (status) {
      case ScheduledTask.statusPending:
        return l10n.scheduledTasks_status_pending;
      case ScheduledTask.statusActive:
        return l10n.scheduledTasks_status_active;
      case ScheduledTask.statusPaused:
        return l10n.scheduledTasks_status_paused;
      case ScheduledTask.statusCompleted:
        return l10n.scheduledTasks_status_completed;
      case ScheduledTask.statusFailed:
        return l10n.scheduledTasks_status_failed;
      default:
        return status;
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case ScheduledTask.statusActive:
        return Colors.green;
      case ScheduledTask.statusPaused:
        return Colors.orange;
      case ScheduledTask.statusCompleted:
        return Colors.blue;
      case ScheduledTask.statusFailed:
        return Colors.red;
      default:
        return Colors.grey;
    }
  }
}
