import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../helpers/cron_parser.dart';
import '../../l10n/app_localizations.dart';
import '../models/scheduled_task.dart';
import '../../models/remote_agent.dart';
import '../../models/channel.dart';
import '../../services/logger_service.dart';
import '../../services/local_database_service.dart';
import '../../services/remote_agent_service.dart';
import '../../services/token_service.dart';
import '../services/scheduled_task_service.dart';

/// Enum for the three schedule modes available in the form.
enum _ScheduleMode { interval, cron, once }

/// Enum for the cron frequency sub-mode.
enum _CronFrequency { daily, weekly, monthly, custom }

/// Full-page form for creating or editing a scheduled task.
/// Uses the same embedded-page pattern as [AddRemoteAgentScreen].
class ScheduledTaskFormScreen extends StatefulWidget {
  /// If null, we are creating a new task.
  final ScheduledTask? task;

  /// Pre-loaded agents. If empty, the screen will load them from the database.
  final List<RemoteAgent> agents;

  /// Called after save (or cancel). The caller is responsible for navigation.
  final VoidCallback onDone;

  const ScheduledTaskFormScreen({
    Key? key,
    this.task,
    this.agents = const [],
    required this.onDone,
  }) : super(key: key);

  @override
  State<ScheduledTaskFormScreen> createState() =>
      _ScheduledTaskFormScreenState();
}

class _ScheduledTaskFormScreenState extends State<ScheduledTaskFormScreen> {
  // ── Execution target ──────────────────────────────────────────────────────
  late String _executionTarget;
  late String? _selectedAgentId;
  late String? _selectedChannelId; // only used for group target
  late List<String> _selectedAgentIds;
  late List<String> _selectedMentionedAgentIds;

  // ── Task content ──────────────────────────────────────────────────────────
  late TextEditingController _descriptionController;
  late TextEditingController _instructionController;

  // ── Schedule mode ─────────────────────────────────────────────────────────
  late _ScheduleMode _scheduleMode;

  // Interval
  late TextEditingController _intervalValueController;
  late String _intervalUnit; // 'minutes' | 'hours' | 'days'

  // Cron
  late _CronFrequency _cronFrequency;
  late int _cronHour;
  late int _cronMinute;
  late Set<int> _cronWeekdays; // 0=Sun,1=Mon,...,6=Sat (cron convention)
  late Set<int> _cronMonthdays; // 1-31
  late TextEditingController _cronCustomController;
  bool _showCronExpression = false;

  // Once
  DateTime? _onceDateTime;

  // ── UI state ──────────────────────────────────────────────────────────────
  bool _saving = false;
  List<Channel> _channels = [];       // group channels (for group target)
  bool _loadingChannels = false;
  List<RemoteAgent> _agents = [];
  bool _loadingAgents = false;

  // ─────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    final task = widget.task;

    // Execution target
    _executionTarget = task?.executionTarget ?? ScheduledTask.targetAgent;
    _selectedAgentId = task?.agentId;
    _selectedChannelId = task?.channelId;
    _selectedAgentIds = List<String>.from(task?.agentIds ?? []);
    _selectedMentionedAgentIds =
        List<String>.from(task?.mentionedAgentIds ?? []);

    // Content
    _descriptionController =
        TextEditingController(text: task?.description ?? '');
    _instructionController =
        TextEditingController(text: task?.instruction ?? '');

    // Schedule – parse existing pattern when editing
    _scheduleMode = _ScheduleMode.interval;
    _intervalValueController = TextEditingController(text: '5');
    _intervalUnit = 'minutes';
    _cronFrequency = _CronFrequency.daily;
    _cronHour = 9;
    _cronMinute = 0;
    _cronWeekdays = {1, 2, 3, 4, 5}; // Mon-Fri default
    _cronMonthdays = {1};
    _cronCustomController = TextEditingController();

    if (task != null) {
      _parseExistingPattern(task.schedulePattern, task.taskType);
    }

    _loadChannels();
    _agents = List.from(widget.agents);
    if (_agents.isEmpty) {
      _loadAgents();
    }
  }

  /// Reverse-parse an existing schedule pattern into the UI state.
  void _parseExistingPattern(String pattern, String taskType) {
    if (taskType == ScheduledTask.typeOnce) {
      _scheduleMode = _ScheduleMode.once;
      // pattern is a timestamp stored as ms string or ISO date
      final ms = int.tryParse(pattern);
      if (ms != null) {
        _onceDateTime = DateTime.fromMillisecondsSinceEpoch(ms);
      }
      return;
    }

    if (pattern.toUpperCase().startsWith('P')) {
      // ISO 8601 interval
      _scheduleMode = _ScheduleMode.interval;
      final dur = CronParser.parseIsoDuration(pattern);
      if (dur != null) {
        if (dur.inDays > 0 && dur.inDays % 1 == 0 && dur.inHours == dur.inDays * 24) {
          _intervalValueController.text = dur.inDays.toString();
          _intervalUnit = 'days';
        } else if (dur.inHours > 0 && dur.inMinutes == dur.inHours * 60) {
          _intervalValueController.text = dur.inHours.toString();
          _intervalUnit = 'hours';
        } else {
          _intervalValueController.text = dur.inMinutes.toString();
          _intervalUnit = 'minutes';
        }
      }
      return;
    }

    // Cron expression
    _scheduleMode = _ScheduleMode.cron;
    final parts = pattern.trim().split(RegExp(r'\s+'));
    if (parts.length == 5) {
      _cronMinute = int.tryParse(parts[0]) ?? 0;
      _cronHour = int.tryParse(parts[1]) ?? 9;
      final domPart = parts[2];
      final dowPart = parts[4];

      if (domPart == '*' && dowPart == '*') {
        _cronFrequency = _CronFrequency.daily;
      } else if (domPart == '*' && dowPart != '*') {
        _cronFrequency = _CronFrequency.weekly;
        _cronWeekdays = _parseCronList(dowPart, 0, 6).toSet();
      } else if (domPart != '*' && dowPart == '*') {
        _cronFrequency = _CronFrequency.monthly;
        _cronMonthdays = _parseCronList(domPart, 1, 31).toSet();
      } else {
        _cronFrequency = _CronFrequency.custom;
        _cronCustomController.text = pattern;
      }
    } else {
      _cronFrequency = _CronFrequency.custom;
      _cronCustomController.text = pattern;
    }
  }

  List<int> _parseCronList(String part, int min, int max) {
    if (part == '*') return List.generate(max - min + 1, (i) => min + i);
    if (part.contains(',')) {
      return part.split(',').map((s) => int.tryParse(s.trim()) ?? min).toList();
    }
    if (part.contains('-')) {
      final ps = part.split('-');
      final s = int.tryParse(ps[0]) ?? min;
      final e = int.tryParse(ps[1]) ?? max;
      return List.generate(e - s + 1, (i) => s + i);
    }
    return [int.tryParse(part) ?? min];
  }

  Future<void> _loadChannels() async {
    setState(() => _loadingChannels = true);
    try {
      final channels = await LocalDatabaseService().getAllChannels();
      if (mounted) {
        setState(() {
          _channels = channels
              .where((c) => c.type == 'group' && c.parentGroupId == null)
              .toList();
          _loadingChannels = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingChannels = false);
    }
  }

  Future<void> _loadAgents() async {
    setState(() => _loadingAgents = true);
    try {
      final db = LocalDatabaseService();
      final tokenService = TokenService(db);
      final agentService = RemoteAgentService(db, tokenService);
      final agents = await agentService.getAllAgents();
      if (mounted) {
        setState(() {
          _agents = agents;
          _loadingAgents = false;
        });
      }
    } catch (e) {
      LoggerService().error('Failed to load agents', error: e, tag: 'ScheduledTaskForm');
      if (mounted) setState(() => _loadingAgents = false);
    }
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _instructionController.dispose();
    _intervalValueController.dispose();
    _cronCustomController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────────────

  List<ChannelMember> get _channelAgentMembers {
    if (_selectedChannelId == null) return [];
    final channel = _channels.firstWhere(
      (c) => c.id == _selectedChannelId,
      orElse: () =>
          Channel(id: '', name: '', type: '', members: [], createdBy: ''),
    );
    return channel.members.where((m) => m.isAgent).toList();
  }

  /// Build the ISO 8601 / cron pattern string from current UI state.
  String _buildSchedulePattern() {
    switch (_scheduleMode) {
      case _ScheduleMode.interval:
        final v = int.tryParse(_intervalValueController.text.trim()) ?? 1;
        switch (_intervalUnit) {
          case 'hours':
            return 'PT${v}H';
          case 'days':
            return 'P${v}D';
          default:
            return 'PT${v}M';
        }
      case _ScheduleMode.cron:
        return _buildCronExpression();
      case _ScheduleMode.once:
        return (_onceDateTime?.millisecondsSinceEpoch ?? 0).toString();
    }
  }

  String _buildCronExpression() {
    final m = _cronMinute.toString().padLeft(2, '0');
    final h = _cronHour.toString();
    switch (_cronFrequency) {
      case _CronFrequency.daily:
        return '$m $h * * *';
      case _CronFrequency.weekly:
        if (_cronWeekdays.isEmpty) return '$m $h * * *';
        final days =
            (_cronWeekdays.toList()..sort()).map((d) => d.toString()).join(',');
        return '$m $h * * $days';
      case _CronFrequency.monthly:
        if (_cronMonthdays.isEmpty) return '$m $h 1 * *';
        final days =
            (_cronMonthdays.toList()..sort()).map((d) => d.toString()).join(',');
        return '$m $h $days * *';
      case _CronFrequency.custom:
        return _cronCustomController.text.trim();
    }
  }

  List<DateTime> _previewCronTimes() {
    final expr = _buildCronExpression();
    if (!CronParser.isValidCron(expr)) return [];
    final times = <DateTime>[];
    int from = DateTime.now().millisecondsSinceEpoch;
    for (int i = 0; i < 3; i++) {
      final next = CronParser.calculateNextCronRun(expr, fromTime: from);
      if (next == null) break;
      times.add(DateTime.fromMillisecondsSinceEpoch(next));
      from = next;
    }
    return times;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Validation & Save
  // ─────────────────────────────────────────────────────────────────────────

  String? _validateSchedule(AppLocalizations l10n) {
    switch (_scheduleMode) {
      case _ScheduleMode.interval:
        final v = int.tryParse(_intervalValueController.text.trim());
        if (v == null || v < 1) return l10n.scheduledTasks_form_invalidInterval;
        return null;
      case _ScheduleMode.cron:
        if (_cronFrequency == _CronFrequency.custom) {
          if (!CronParser.isValidCron(_cronCustomController.text.trim())) {
            return l10n.scheduledTasks_form_invalidCron;
          }
        } else if (_cronFrequency == _CronFrequency.weekly &&
            _cronWeekdays.isEmpty) {
          return l10n.scheduledTasks_form_invalidCron;
        } else if (_cronFrequency == _CronFrequency.monthly &&
            _cronMonthdays.isEmpty) {
          return l10n.scheduledTasks_form_invalidCron;
        }
        return null;
      case _ScheduleMode.once:
        if (_onceDateTime == null) return l10n.scheduledTasks_form_invalidOnce;
        if (_onceDateTime!.isBefore(DateTime.now())) {
          return l10n.scheduledTasks_form_oncePastError;
        }
        return null;
    }
  }

  Future<void> _saveTask(AppLocalizations l10n) async {
    // Validate target
    if (_executionTarget == ScheduledTask.targetAgent) {
      if (_selectedAgentId == null) {
        _showSnack(l10n.scheduledTasks_missingAgent);
        return;
      }
    } else {
      if (_selectedChannelId == null) {
        _showSnack(l10n.scheduledTasks_missingChannel);
        return;
      }
      if (_selectedAgentIds.isEmpty) {
        _showSnack(l10n.scheduledTasks_missingGroupAgents);
        return;
      }
    }

    // Validate content
    if (_instructionController.text.trim().isEmpty) {
      _showSnack(l10n.scheduledTasks_missingInstruction);
      return;
    }

    // Validate schedule
    final scheduleError = _validateSchedule(l10n);
    if (scheduleError != null) {
      _showSnack(scheduleError);
      return;
    }

    setState(() => _saving = true);
    try {
      final taskService = ScheduledTaskService();
      final pattern = _buildSchedulePattern();

      if (widget.task == null) {
        final newTask = await taskService.createScheduledTask(
          agentId: _executionTarget == ScheduledTask.targetAgent
              ? _selectedAgentId
              : null,
          channelId: _executionTarget == ScheduledTask.targetGroup
              ? _selectedChannelId
              : null,
          executionTarget: _executionTarget,
          agentIds: _executionTarget == ScheduledTask.targetGroup
              ? _selectedAgentIds
              : const [],
          mentionedAgentIds: _executionTarget == ScheduledTask.targetGroup
              ? _selectedMentionedAgentIds
              : const [],
          instruction: _instructionController.text.trim(),
          schedulePattern: pattern,
          description: _descriptionController.text.trim(),
        );
        taskService.activateScheduledTask(newTask.id).catchError((e) {
          LoggerService()
              .error('Failed to activate task', error: e, tag: 'ScheduledTasks');
        });
        if (mounted) {
          _showSnack(l10n.scheduledTasks_createSuccess);
          widget.onDone();
        }
      } else {
        final updated = widget.task!.copyWith(
          description: _descriptionController.text.trim(),
          instruction: _instructionController.text.trim(),
          schedulePattern: pattern,
          executionTarget: _executionTarget,
          agentId: _executionTarget == ScheduledTask.targetAgent
              ? _selectedAgentId
              : null,
          channelId: _executionTarget == ScheduledTask.targetGroup
              ? _selectedChannelId
              : null,
          agentIds: _executionTarget == ScheduledTask.targetGroup
              ? _selectedAgentIds
              : const [],
          mentionedAgentIds: _executionTarget == ScheduledTask.targetGroup
              ? _selectedMentionedAgentIds
              : const [],
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
        await taskService.updateScheduledTask(updated);
        if (mounted) {
          _showSnack(l10n.scheduledTasks_updateSuccess);
          widget.onDone();
        }
      }
    } catch (e) {
      if (mounted) _showSnack('Error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isCreating = widget.task == null;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onDone,
        ),
        title: Text(isCreating
            ? l10n.scheduledTasks_createTask
            : l10n.scheduledTasks_editTask),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSectionCard(
                    context: context,
                    colorScheme: colorScheme,
                    icon: Icons.people_alt_outlined,
                    title: l10n.scheduledTasks_form_targetSection,
                    child: _buildTargetSection(l10n, colorScheme),
                  ),
                  const SizedBox(height: 12),
                  _buildSectionCard(
                    context: context,
                    colorScheme: colorScheme,
                    icon: Icons.article_outlined,
                    title: l10n.scheduledTasks_form_contentSection,
                    child: _buildContentSection(l10n),
                  ),
                  const SizedBox(height: 12),
                  _buildSectionCard(
                    context: context,
                    colorScheme: colorScheme,
                    icon: Icons.schedule,
                    title: l10n.scheduledTasks_form_scheduleSection,
                    child: _buildScheduleSection(l10n, colorScheme),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          _buildBottomBar(l10n, colorScheme),
        ],
      ),
    );
  }

  // ── Section card wrapper ─────────────────────────────────────────────────

  Widget _buildSectionCard({
    required BuildContext context,
    required ColorScheme colorScheme,
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }

  // ── Execution target section ─────────────────────────────────────────────

  Widget _buildTargetSection(AppLocalizations l10n, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: SegmentedButton<String>(
            segments: [
              ButtonSegment(
                value: ScheduledTask.targetAgent,
                label: Text(l10n.scheduledTasks_targetAgent),
                icon: const Icon(Icons.smart_toy_outlined),
              ),
              ButtonSegment(
                value: ScheduledTask.targetGroup,
                label: Text(l10n.scheduledTasks_targetGroup),
                icon: const Icon(Icons.group_outlined),
              ),
            ],
            selected: {_executionTarget},
            onSelectionChanged: (v) {
              setState(() {
                _executionTarget = v.first;
                _selectedAgentId = null;
                _selectedChannelId = null;
                _selectedAgentIds = [];
                _selectedMentionedAgentIds = [];
              });
            },
          ),
        ),
        const SizedBox(height: 16),
        if (_executionTarget == ScheduledTask.targetAgent) ...[
          if (_loadingAgents)
            const Center(child: CircularProgressIndicator())
          else
            DropdownButtonFormField<String?>(
              value: _selectedAgentId,
              decoration: InputDecoration(
                labelText: l10n.scheduledTasks_form_selectAgent,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.smart_toy_outlined),
              ),
              items: _agents
                  .map((a) => DropdownMenuItem(value: a.id, child: Text(a.name)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedAgentId = v),
            ),
        ] else ...[
          if (_loadingChannels)
            const Center(child: CircularProgressIndicator())
          else
            DropdownButtonFormField<String?>(
              value: _channels.any((c) => c.id == _selectedChannelId)
                  ? _selectedChannelId
                  : null,
              decoration: InputDecoration(
                labelText: l10n.scheduledTasks_form_selectGroup,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.group_outlined),
              ),
              items: _channels
                  .map((c) =>
                      DropdownMenuItem(value: c.id, child: Text(c.name)))
                  .toList(),
              onChanged: (v) {
                setState(() {
                  _selectedChannelId = v;
                  _selectedAgentIds = [];
                  _selectedMentionedAgentIds = [];
                });
              },
            ),
          if (_selectedChannelId != null &&
              _channelAgentMembers.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(l10n.scheduledTasks_form_selectGroupAgents,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _channelAgentMembers.map((m) {
                final agent = _agents.firstWhere(
                  (a) => a.id == m.id,
                  orElse: () => RemoteAgent(
                    id: m.id,
                    name: m.id,
                    token: '',
                    endpoint: '',
                    protocol: ProtocolType.acp,
                    connectionType: ConnectionType.websocket,
                    createdAt: 0,
                    updatedAt: 0,
                  ),
                );
                final selected = _selectedAgentIds.contains(m.id);
                return FilterChip(
                  label: Text(agent.name),
                  selected: selected,
                  onSelected: (on) {
                    setState(() {
                      if (on) {
                        _selectedAgentIds.add(m.id);
                      } else {
                        _selectedAgentIds.remove(m.id);
                        _selectedMentionedAgentIds.remove(m.id);
                      }
                    });
                  },
                );
              }).toList(),
            ),
            if (_selectedAgentIds.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(l10n.scheduledTasks_form_selectMentions,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: _selectedAgentIds.map((id) {
                  final agent = _agents.firstWhere(
                    (a) => a.id == id,
                    orElse: () => RemoteAgent(
                      id: id,
                      name: id,
                      token: '',
                      endpoint: '',
                      protocol: ProtocolType.acp,
                      connectionType: ConnectionType.websocket,
                      createdAt: 0,
                      updatedAt: 0,
                    ),
                  );
                  final mentioned = _selectedMentionedAgentIds.contains(id);
                  return FilterChip(
                    label: Text(agent.name),
                    selected: mentioned,
                    onSelected: (on) {
                      setState(() {
                        if (on) {
                          _selectedMentionedAgentIds.add(id);
                        } else {
                          _selectedMentionedAgentIds.remove(id);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
            ],
          ],
        ],
      ],
    );
  }

  // ── Content section ──────────────────────────────────────────────────────

  Widget _buildContentSection(AppLocalizations l10n) {
    return Column(
      children: [
        TextField(
          controller: _descriptionController,
          decoration: InputDecoration(
            labelText: l10n.scheduledTasks_form_description,
            hintText: l10n.scheduledTasks_form_descriptionHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _instructionController,
          decoration: InputDecoration(
            labelText: l10n.scheduledTasks_form_instruction,
            hintText: l10n.scheduledTasks_form_instructionHint,
            border: const OutlineInputBorder(),
          ),
          maxLines: 4,
          minLines: 3,
        ),
      ],
    );
  }

  // ── Schedule section ─────────────────────────────────────────────────────

  Widget _buildScheduleSection(AppLocalizations l10n, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Mode toggle
        SegmentedButton<_ScheduleMode>(
          segments: [
            ButtonSegment(
              value: _ScheduleMode.interval,
              label: Text(l10n.scheduledTasks_form_scheduleType_interval),
              icon: const Icon(Icons.repeat),
            ),
            ButtonSegment(
              value: _ScheduleMode.cron,
              label: Text(l10n.scheduledTasks_form_scheduleType_cron),
              icon: const Icon(Icons.calendar_today_outlined),
            ),
            ButtonSegment(
              value: _ScheduleMode.once,
              label: Text(l10n.scheduledTasks_form_scheduleType_once),
              icon: const Icon(Icons.looks_one_outlined),
            ),
          ],
          selected: {_scheduleMode},
          onSelectionChanged: (v) => setState(() => _scheduleMode = v.first),
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
          ),
        ),
        const SizedBox(height: 16),
        // Mode content
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: KeyedSubtree(
            key: ValueKey(_scheduleMode),
            child: switch (_scheduleMode) {
              _ScheduleMode.interval =>
                _buildIntervalSection(l10n, colorScheme),
              _ScheduleMode.cron => _buildCronSection(l10n, colorScheme),
              _ScheduleMode.once => _buildOnceSection(l10n, colorScheme),
            },
          ),
        ),
      ],
    );
  }

  // ── Interval mode ────────────────────────────────────────────────────────

  Widget _buildIntervalSection(AppLocalizations l10n, ColorScheme colorScheme) {
    final unitLabel = switch (_intervalUnit) {
      'hours' => l10n.scheduledTasks_form_interval_unit_hours,
      'days' => l10n.scheduledTasks_form_interval_unit_days,
      _ => l10n.scheduledTasks_form_interval_unit_minutes,
    };

    // Build preview string
    final v = _intervalValueController.text.trim();
    final previewText = v.isNotEmpty && (int.tryParse(v) ?? 0) >= 1
        ? l10n.scheduledTasks_form_interval_preview(v, unitLabel)
        : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Value + unit row
        Row(
          children: [
            Expanded(
              flex: 2,
              child: TextField(
                controller: _intervalValueController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: l10n.scheduledTasks_form_interval_value,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: DropdownButtonFormField<String>(
                value: _intervalUnit,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(
                    value: 'minutes',
                    child: Text(l10n.scheduledTasks_form_interval_unit_minutes),
                  ),
                  DropdownMenuItem(
                    value: 'hours',
                    child: Text(l10n.scheduledTasks_form_interval_unit_hours),
                  ),
                  DropdownMenuItem(
                    value: 'days',
                    child: Text(l10n.scheduledTasks_form_interval_unit_days),
                  ),
                ],
                onChanged: (v) => setState(() {
                  _intervalUnit = v ?? 'minutes';
                }),
              ),
            ),
          ],
        ),
        // Quick presets
        const SizedBox(height: 12),
        Text(
          l10n.scheduledTasks_form_preset_label,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            _presetChip(l10n.scheduledTasks_form_preset_5min, '5', 'minutes'),
            _presetChip(l10n.scheduledTasks_form_preset_30min, '30', 'minutes'),
            _presetChip(l10n.scheduledTasks_form_preset_1h, '1', 'hours'),
            _presetChip(l10n.scheduledTasks_form_preset_6h, '6', 'hours'),
            _presetChip(l10n.scheduledTasks_form_preset_1d, '1', 'days'),
          ],
        ),
        // Preview
        if (previewText.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildPreviewRow(Icons.info_outline, previewText, colorScheme),
        ],
      ],
    );
  }

  Widget _presetChip(String label, String value, String unit) {
    final isSelected =
        _intervalValueController.text == value && _intervalUnit == unit;
    return ActionChip(
      label: Text(label),
      backgroundColor: isSelected
          ? Theme.of(context).colorScheme.primaryContainer
          : null,
      onPressed: () {
        setState(() {
          _intervalValueController.text = value;
          _intervalUnit = unit;
        });
      },
    );
  }

  // ── Cron mode ────────────────────────────────────────────────────────────

  Widget _buildCronSection(AppLocalizations l10n, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Frequency selector
        _buildLabeledRow(
          label: l10n.scheduledTasks_form_cron_frequency,
          child: DropdownButton<_CronFrequency>(
            value: _cronFrequency,
            underline: const SizedBox.shrink(),
            items: [
              DropdownMenuItem(
                value: _CronFrequency.daily,
                child: Text(l10n.scheduledTasks_form_cron_freq_daily),
              ),
              DropdownMenuItem(
                value: _CronFrequency.weekly,
                child: Text(l10n.scheduledTasks_form_cron_freq_weekly),
              ),
              DropdownMenuItem(
                value: _CronFrequency.monthly,
                child: Text(l10n.scheduledTasks_form_cron_freq_monthly),
              ),
              DropdownMenuItem(
                value: _CronFrequency.custom,
                child: Text(l10n.scheduledTasks_form_cron_freq_custom),
              ),
            ],
            onChanged: (v) => setState(() => _cronFrequency = v!),
          ),
        ),
        if (_cronFrequency != _CronFrequency.custom) ...[
          const SizedBox(height: 12),
          // Time picker
          _buildLabeledRow(
            label: l10n.scheduledTasks_form_cron_time,
            child: _buildTimePicker(l10n),
          ),
        ],
        // Weekday selector
        if (_cronFrequency == _CronFrequency.weekly) ...[
          const SizedBox(height: 14),
          Text(l10n.scheduledTasks_form_cron_weekdays,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          _buildWeekdaySelector(l10n),
        ],
        // Monthly day selector
        if (_cronFrequency == _CronFrequency.monthly) ...[
          const SizedBox(height: 14),
          Text(l10n.scheduledTasks_form_cron_monthdays,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          _buildMonthdaySelector(),
        ],
        // Custom cron input
        if (_cronFrequency == _CronFrequency.custom) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _cronCustomController,
            decoration: InputDecoration(
              labelText: l10n.scheduledTasks_form_schedulePattern,
              hintText: l10n.scheduledTasks_form_cron_custom_hint,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
        const SizedBox(height: 14),
        // Expandable cron expression display
        if (_cronFrequency != _CronFrequency.custom)
          _buildCronExpressionToggle(l10n, colorScheme),
        // Preview upcoming runs
        const SizedBox(height: 10),
        _buildCronPreview(l10n, colorScheme),
      ],
    );
  }

  Widget _buildTimePicker(AppLocalizations l10n) {
    return InkWell(
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(hour: _cronHour, minute: _cronMinute),
        );
        if (picked != null) {
          setState(() {
            _cronHour = picked.hour;
            _cronMinute = picked.minute;
          });
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.access_time, size: 18),
            const SizedBox(width: 8),
            Text(
              '${_cronHour.toString().padLeft(2, '0')}:${_cronMinute.toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildWeekdaySelector(AppLocalizations l10n) {
    final days = [
      (1, l10n.scheduledTasks_form_cron_weekday_mon),
      (2, l10n.scheduledTasks_form_cron_weekday_tue),
      (3, l10n.scheduledTasks_form_cron_weekday_wed),
      (4, l10n.scheduledTasks_form_cron_weekday_thu),
      (5, l10n.scheduledTasks_form_cron_weekday_fri),
      (6, l10n.scheduledTasks_form_cron_weekday_sat),
      (0, l10n.scheduledTasks_form_cron_weekday_sun),
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: days.map((d) {
        final (num, label) = d;
        final selected = _cronWeekdays.contains(num);
        return FilterChip(
          label: Text(label),
          selected: selected,
          onSelected: (on) {
            setState(() {
              if (on) {
                _cronWeekdays.add(num);
              } else {
                _cronWeekdays.remove(num);
              }
            });
          },
        );
      }).toList(),
    );
  }

  Widget _buildMonthdaySelector() {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: List.generate(31, (i) {
        final day = i + 1;
        final selected = _cronMonthdays.contains(day);
        return SizedBox(
          width: 38,
          height: 38,
          child: FilterChip(
            label: Text(
              day.toString(),
              style: const TextStyle(fontSize: 12),
            ),
            selected: selected,
            padding: EdgeInsets.zero,
            labelPadding: EdgeInsets.zero,
            onSelected: (on) {
              setState(() {
                if (on) {
                  _cronMonthdays.add(day);
                } else {
                  _cronMonthdays.remove(day);
                }
              });
            },
          ),
        );
      }),
    );
  }

  Widget _buildCronExpressionToggle(
      AppLocalizations l10n, ColorScheme colorScheme) {
    final expr = _buildCronExpression();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _showCronExpression = !_showCronExpression),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _showCronExpression
                      ? Icons.expand_less
                      : Icons.expand_more,
                  size: 18,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  l10n.scheduledTasks_form_cron_advanced,
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_showCronExpression)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    expr,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 14),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: expr));
                    _showSnack(expr);
                  },
                  tooltip: 'Copy',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildCronPreview(AppLocalizations l10n, ColorScheme colorScheme) {
    List<DateTime> times;
    if (_cronFrequency == _CronFrequency.custom) {
      final expr = _cronCustomController.text.trim();
      if (!CronParser.isValidCron(expr)) return const SizedBox.shrink();
      times = [];
      int from = DateTime.now().millisecondsSinceEpoch;
      for (int i = 0; i < 3; i++) {
        final next = CronParser.calculateNextCronRun(expr, fromTime: from);
        if (next == null) break;
        times.add(DateTime.fromMillisecondsSinceEpoch(next));
        from = next;
      }
    } else {
      times = _previewCronTimes();
    }
    if (times.isEmpty) return const SizedBox.shrink();

    final fmt = DateFormat('MM/dd HH:mm');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.preview, size: 14, color: colorScheme.primary),
              const SizedBox(width: 4),
              Text(
                l10n.scheduledTasks_form_cron_preview,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...times.map((t) => Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '• ${fmt.format(t)}',
                  style: const TextStyle(fontSize: 13),
                ),
              )),
        ],
      ),
    );
  }

  // ── Once mode ────────────────────────────────────────────────────────────

  Widget _buildOnceSection(AppLocalizations l10n, ColorScheme colorScheme) {
    final fmt = DateFormat('yyyy/MM/dd HH:mm');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.scheduledTasks_form_once_datetime,
            style:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(
                  _onceDateTime != null
                      ? DateFormat('yyyy/MM/dd').format(_onceDateTime!)
                      : l10n.scheduledTasks_form_once_pickDate,
                ),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _onceDateTime ?? DateTime.now(),
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
                  );
                  if (picked != null) {
                    setState(() {
                      final existingTime = _onceDateTime;
                      _onceDateTime = DateTime(
                        picked.year,
                        picked.month,
                        picked.day,
                        existingTime?.hour ?? 9,
                        existingTime?.minute ?? 0,
                      );
                    });
                  }
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.access_time, size: 16),
                label: Text(
                  _onceDateTime != null
                      ? DateFormat('HH:mm').format(_onceDateTime!)
                      : l10n.scheduledTasks_form_once_pickTime,
                ),
                onPressed: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(
                      hour: _onceDateTime?.hour ?? 9,
                      minute: _onceDateTime?.minute ?? 0,
                    ),
                  );
                  if (picked != null) {
                    setState(() {
                      final base = _onceDateTime ?? DateTime.now();
                      _onceDateTime = DateTime(
                        base.year,
                        base.month,
                        base.day,
                        picked.hour,
                        picked.minute,
                      );
                    });
                  }
                },
              ),
            ),
          ],
        ),
        if (_onceDateTime != null) ...[
          const SizedBox(height: 12),
          _buildPreviewRow(
            Icons.event_available,
            fmt.format(_onceDateTime!),
            colorScheme,
          ),
        ],
      ],
    );
  }

  // ── Shared helpers ───────────────────────────────────────────────────────

  Widget _buildLabeledRow({required String label, required Widget child}) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
        const SizedBox(width: 8),
        child,
      ],
    );
  }

  Widget _buildPreviewRow(IconData icon, String text, ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, color: cs.onPrimaryContainer)),
          ),
        ],
      ),
    );
  }

  // ── Bottom bar ───────────────────────────────────────────────────────────

  Widget _buildBottomBar(AppLocalizations l10n, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _saving ? null : widget.onDone,
              child: Text(l10n.common_cancel),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: FilledButton.icon(
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.check, size: 18),
              label: Text(l10n.scheduledTasks_form_saveAndActivate),
              onPressed: _saving ? null : () => _saveTask(l10n),
            ),
          ),
        ],
      ),
    );
  }
}
