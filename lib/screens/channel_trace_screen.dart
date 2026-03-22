import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/inference_log_entry.dart';
import '../models/trace_models.dart';
import '../services/trace_service.dart';

/// Per-channel trace list and detail viewer.
///
/// Accessible from the chat AppBar via the psychology icon.
/// Shows traces for the given [channelId] (or all traces if channelId is null).
class ChannelTraceScreen extends StatefulWidget {
  final String? channelId;
  final String? channelName;
  /// When provided, the back button calls this instead of Navigator.pop.
  /// Used on desktop where the screen is a panel root, not a pushed route.
  final VoidCallback? onBack;

  const ChannelTraceScreen({
    super.key,
    this.channelId,
    this.channelName,
    this.onBack,
  });

  @override
  State<ChannelTraceScreen> createState() => _ChannelTraceScreenState();
}

class _ChannelTraceScreenState extends State<ChannelTraceScreen> {
  final _service = TraceService.instance;

  List<TraceEntry> _traces = [];
  bool _loading = true;
  String? _selectedTraceId;

  @override
  void initState() {
    super.initState();
    _service.addListener(_reload);
    _load();
  }

  @override
  void dispose() {
    _service.removeListener(_reload);
    super.dispose();
  }

  void _reload() => _load();

  Future<void> _load() async {
    setState(() => _loading = true);
    final traces = await _service.queryTraces(
      channelId: widget.channelId,
      limit: 100,
    );
    if (mounted) {
      setState(() {
        _traces = traces;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final completed = _traces.where((t) => t.status == InferenceStatus.completed).length;
    final errors = _traces.where((t) => t.status == InferenceStatus.error).length;
    final inProgress = _traces.where((t) => t.status == InferenceStatus.inProgress).length;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBack ?? () => Navigator.pop(context),
        ),
        title: Text(widget.channelName != null
            ? 'Traces — ${widget.channelName}'
            : 'Agent Traces'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'clear') _confirmClear();
              if (value == 'export') _export();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'export',
                child: ListTile(
                  leading: Icon(Icons.share),
                  title: Text('Export JSONL'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'clear',
                child: ListTile(
                  leading: const Icon(Icons.delete, color: Colors.red),
                  title: Text(
                    widget.channelId != null ? 'Clear channel traces' : 'Clear all traces',
                    style: const TextStyle(color: Colors.red),
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Stats bar
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            color: theme.colorScheme.surfaceContainerHighest,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _statChip('Total', _traces.length, Colors.blue),
                _statChip('Done', completed, Colors.green),
                _statChip('Error', errors, Colors.red),
                _statChip('Active', inProgress, Colors.orange),
              ],
            ),
          ),

          // List
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _traces.isEmpty
                    ? _buildEmpty()
                    : ListView.builder(
                        itemCount: _traces.length,
                        itemBuilder: (_, i) => _buildTraceCard(_traces[i]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.psychology_outlined, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text('No traces yet',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 16)),
          const SizedBox(height: 8),
          Text('Traces will appear here after agent interactions',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildTraceCard(TraceEntry trace) {
    final isSelected = trace.id == _selectedTraceId;
    final isOrchestration = trace.traceRole == 'group_orchestration';
    final isChildAgent = trace.parentTraceId != null;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: isSelected ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.4) : null,
      child: ListTile(
        leading: isOrchestration
            ? Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: Colors.deepOrange.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.deepOrange.withValues(alpha: 0.4)),
                ),
                child: const Icon(Icons.account_tree, size: 20, color: Colors.deepOrange),
              )
            : _statusIcon(trace.status),
        title: Text(
          isOrchestration
              ? 'Orchestration — ${trace.agentName}'
              : '${trace.agentName} — ${trace.model ?? "unknown"}',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _formatTime(trace.startTime),
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
            Row(
              children: [
                _chip(trace.durationLabel, Colors.blue.shade50, Colors.blue),
                const SizedBox(width: 4),
                if (isOrchestration)
                  _chip(trace.executionMode ?? 'orchestration',
                      Colors.deepOrange.shade50, Colors.deepOrange)
                else ...[
                  _chip('${trace.totalRounds}r', Colors.purple.shade50, Colors.purple),
                  const SizedBox(width: 4),
                  _chip('${trace.totalToolCalls}t', Colors.teal.shade50, Colors.teal),
                ],
                if (isChildAgent) ...[
                  const SizedBox(width: 4),
                  _chip(
                    trace.traceRole == 'group_admin' ? 'Admin' : 'Member',
                    trace.traceRole == 'group_admin' ? Colors.orange.shade50 : Colors.teal.shade50,
                    trace.traceRole == 'group_admin' ? Colors.orange : Colors.teal,
                  ),
                ],
              ],
            ),
            Text(
              trace.userMessage.length > 60
                  ? '${trace.userMessage.substring(0, 60)}...'
                  : trace.userMessage,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        isThreeLine: true,
        onTap: () => _openDetail(trace),
        trailing: const Icon(Icons.chevron_right, size: 20),
      ),
    );
  }

  Widget _chip(String label, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: fg, fontWeight: FontWeight.w600)),
    );
  }

  Widget _statChip(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          '$count',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color),
        ),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  Icon _statusIcon(InferenceStatus status) {
    switch (status) {
      case InferenceStatus.inProgress:
        return const Icon(Icons.hourglass_top, color: Colors.orange);
      case InferenceStatus.completed:
        return const Icon(Icons.check_circle, color: Colors.green);
      case InferenceStatus.error:
        return const Icon(Icons.error, color: Colors.red);
      case InferenceStatus.cancelled:
        return const Icon(Icons.cancel, color: Colors.grey);
    }
  }

  String _formatTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')} '
        '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}:${dt.second.toString().padLeft(2,'0')}';
  }

  void _openDetail(TraceEntry trace) {
    setState(() => _selectedTraceId = trace.id);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TraceDetailScreen(traceId: trace.id),
      ),
    );
  }

  Future<void> _confirmClear() async {
    final isChannelScoped = widget.channelId != null;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isChannelScoped ? 'Clear channel traces' : 'Clear all traces'),
        content: Text(
          isChannelScoped
              ? 'This will permanently delete all traces for '
                '"${widget.channelName ?? widget.channelId}". Continue?'
              : 'This will permanently delete all trace records. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      if (isChannelScoped) {
        await _service.clearByChannel(widget.channelId!);
      } else {
        await _service.clearAll();
      }
      _load();
    }
  }

  Future<void> _export() async {
    final jsonl = await _service.exportAsJsonl();
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export JSONL'),
        content: SizedBox(
          width: double.maxFinite,
          height: 200,
          child: SingleChildScrollView(
            child: SelectableText(
              jsonl.isEmpty ? '(no data)' : jsonl,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: jsonl));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard')),
              );
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Detail screen — stepper-like trace view
// =============================================================================

class TraceDetailScreen extends StatefulWidget {
  final String traceId;

  const TraceDetailScreen({super.key, required this.traceId});

  @override
  State<TraceDetailScreen> createState() => _TraceDetailScreenState();
}

class _TraceDetailScreenState extends State<TraceDetailScreen> {
  TraceEntry? _trace;
  List<TraceEntry> _childTraces = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final trace = await TraceService.instance.getTraceDetail(widget.traceId);
    List<TraceEntry> children = [];
    if (trace?.traceRole == 'group_orchestration') {
      children = await TraceService.instance.getChildTraces(widget.traceId);
    }
    if (mounted) {
      setState(() {
        _trace = trace;
        _childTraces = children;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trace Detail'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy JSON',
            onPressed: _trace == null ? null : () {
              final json = const JsonEncoder.withIndent('  ').convert(_trace!.toJson());
              Clipboard.setData(ClipboardData(text: json));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied')),
              );
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _trace == null
              ? const Center(child: Text('Trace not found'))
              : _buildDetail(_trace!),    );
  }

  Widget _buildDetail(TraceEntry trace) {
    final spans = trace.spans ?? [];
    final isOrchestration = trace.traceRole == 'group_orchestration';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Header card
        _buildHeaderCard(trace),
        const SizedBox(height: 16),

        // System prompt (collapsible) — for orchestration traces this holds config JSON
        if (trace.systemPrompt != null && trace.systemPrompt!.isNotEmpty)
          _buildCollapsibleSection(
            icon: isOrchestration ? Icons.settings_suggest : Icons.settings,
            iconColor: isOrchestration ? Colors.orange.shade700 : Colors.grey,
            title: isOrchestration ? 'Orchestration Config' : 'System Prompt',
            content: trace.systemPrompt!,
            defaultExpanded: false,
          ),

        // User message
        _buildUserMessageCard(trace.userMessage),
        const SizedBox(height: 8),

        // Orchestration spans (dispatch_decision, plan_approval, etc.)
        if (isOrchestration) ...[
          ..._buildOrchestrationSteps(spans),
          // Child agent traces
          if (_childTraces.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildChildTracesSection(_childTraces),
          ],
        ] else ...[
          // Regular agent spans
          ..._buildSteps(spans),
        ],

        // Error
        if (trace.errorMessage != null)
          _buildErrorCard(trace.errorMessage!),

        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildHeaderCard(TraceEntry trace) {
    final isOrchestration = trace.traceRole == 'group_orchestration';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _statusIcon(trace.status),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isOrchestration
                        ? 'Orchestration — ${trace.agentName}'
                        : '${trace.agentName} — ${trace.model ?? "unknown"}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _modeColor(trace.executionMode).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: _modeColor(trace.executionMode).withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    trace.executionMode ?? 'unknown',
                    style: TextStyle(
                      fontSize: 10,
                      color: _modeColor(trace.executionMode),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'ID: ${trace.id}',
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey.shade500,
                fontFamily: 'monospace',
              ),
            ),
            if (trace.parentTraceId != null) ...[
              const SizedBox(height: 2),
              Text(
                'Parent: ${trace.parentTraceId}',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.orange.shade400,
                  fontFamily: 'monospace',
                ),
              ),
            ],
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              children: [
                _metaItem(Icons.timer, trace.durationLabel),
                if (!isOrchestration) ...[
                  _metaItem(Icons.loop, '${trace.totalRounds} rounds'),
                  _metaItem(Icons.build, '${trace.totalToolCalls} tool calls'),
                  _metaItem(Icons.text_fields, '${trace.totalTextChars} chars'),
                ] else ...[
                  _metaItem(Icons.people, '${_childTraces.length} agents'),
                ],
                if (trace.provider != null)
                  _metaItem(Icons.cloud, trace.provider!),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metaItem(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: Colors.grey.shade500),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      ],
    );
  }

  Widget _buildUserMessageCard(String message) {
    return _StepCard(
      icon: Icons.person,
      iconColor: Colors.blue.shade700,
      lineColor: Colors.blue.shade200,
      title: 'User Message',
      child: SelectableText(
        message,
        style: const TextStyle(fontSize: 13),
      ),
    );
  }

  List<Widget> _buildSteps(List<TraceSpan> spans) {
    final result = <Widget>[];
    final llmCalls = spans.where((s) => s.spanType == 'llm_call').toList();

    for (int i = 0; i < llmCalls.length; i++) {
      final llmSpan = llmCalls[i];
      // Find tool_calls that are children of this llm_call
      final toolCalls = spans
          .where((s) => s.spanType == 'tool_call' && s.parentSpanId == llmSpan.id)
          .toList();

      result.add(_buildLlmCallCard(llmSpan, toolCalls, i + 1));
      result.add(const SizedBox(height: 8));
    }

    // Tool calls without a parent (should not happen in normal flow, but show them anyway)
    final orphanedTools = spans
        .where((s) => s.spanType == 'tool_call' &&
            (s.parentSpanId == null ||
                !spans.any((ls) => ls.id == s.parentSpanId)))
        .toList();
    for (final tc in orphanedTools) {
      result.add(_buildToolCallCard(tc));
      result.add(const SizedBox(height: 8));
    }

    return result;
  }

  /// Build steps for orchestration root traces (dispatch_decision, plan_approval, etc.)
  List<Widget> _buildOrchestrationSteps(List<TraceSpan> spans) {
    final result = <Widget>[];
    final orchSpans = spans.where((s) =>
        s.spanType == 'dispatch_decision' ||
        s.spanType == 'plan_approval' ||
        s.spanType == 'orchestration_round' ||
        s.spanType == 'agent_delegation').toList();

    for (final span in orchSpans) {
      result.add(_buildOrchSpanCard(span));
      result.add(const SizedBox(height: 8));
    }
    return result;
  }

  Widget _buildOrchSpanCard(TraceSpan span) {
    final inputData = span.inputDataJson;
    final (IconData icon, Color color, String label) = switch (span.spanType) {
      'dispatch_decision' => (Icons.account_tree, Colors.deepOrange, 'Dispatch'),
      'plan_approval'     => (Icons.rule, Colors.amber.shade800, 'Plan Approval'),
      'agent_delegation'  => (Icons.send, Colors.teal, 'Delegation'),
      _                   => (Icons.timeline, Colors.blueGrey, span.spanType),
    };

    return _StepCard(
      icon: icon,
      iconColor: color,
      lineColor: color.withValues(alpha: 0.4),
      title: span.name ?? label,
      trailing: Text(
        span.durationLabel,
        style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (inputData != null) ...[
            // Dispatch decision: show delegated_ids and wants_continue prominently
            if (span.spanType == 'dispatch_decision') ...[
              _buildDispatchSummary(inputData),
            ] else if (span.spanType == 'plan_approval') ...[
              _buildPlanApprovalSummary(inputData, span.outputDataJson),
            ] else ...[
              _label('Data:'),
              _codeBlock(_prettyJson(inputData)),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildDispatchSummary(Map<String, dynamic> data) {
    final delegatedIds = (data['delegated_ids'] as List?)?.cast<String>() ?? [];
    final wantsContinue = data['wants_continue'] as bool? ?? false;
    final isDone = data['is_done'] as bool? ?? false;
    final stepCount = data['step_count'] as int? ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            _chip(isDone ? 'Done' : wantsContinue ? 'Continue' : 'Delegate',
                isDone ? Colors.green.shade50 : wantsContinue ? Colors.blue.shade50 : Colors.orange.shade50,
                isDone ? Colors.green : wantsContinue ? Colors.blue : Colors.orange),
            if (stepCount > 0)
              _chip('$stepCount steps', Colors.purple.shade50, Colors.purple),
          ],
        ),
        if (delegatedIds.isNotEmpty) ...[
          const SizedBox(height: 6),
          _label('Delegated agents:'),
          const SizedBox(height: 2),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: delegatedIds
                .map((id) => _chip(id.length > 8 ? '${id.substring(0, 8)}…' : id,
                    Colors.teal.shade50, Colors.teal))
                .toList(),
          ),
        ],
      ],
    );
  }

  Widget _buildPlanApprovalSummary(Map<String, dynamic> input, Map<String, dynamic>? output) {
    final taskCount = input['task_count'] as int?;
    final approved = output?['approved'] as bool?;
    final hasFeedback = output?['has_feedback'] as bool? ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          children: [
            if (taskCount != null)
              _chip('$taskCount tasks', Colors.blue.shade50, Colors.blue),
            if (approved != null)
              _chip(approved ? 'Approved' : 'Rejected',
                  approved ? Colors.green.shade50 : Colors.red.shade50,
                  approved ? Colors.green : Colors.red),
            if (hasFeedback)
              _chip('Has feedback', Colors.amber.shade50, Colors.amber.shade800),
          ],
        ),
      ],
    );
  }

  Widget _buildChildTracesSection(List<TraceEntry> children) {
    return _StepCard(
      icon: Icons.people,
      iconColor: Colors.indigo,
      lineColor: Colors.indigo.shade200,
      title: 'Agent Traces (${children.length})',
      child: Column(
        children: children.map((child) => _buildChildTraceRow(child)).toList(),
      ),
    );
  }

  Widget _buildChildTraceRow(TraceEntry child) {
    final roleColor = child.traceRole == 'group_admin' ? Colors.orange : Colors.teal;
    final roleLabel = child.traceRole == 'group_admin' ? 'Admin' : 'Member';

    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => TraceDetailScreen(traceId: child.id)),
      ),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: roleColor.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(6),
          color: roleColor.withValues(alpha: 0.05),
        ),
        child: Row(
          children: [
            _statusIcon(child.status),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    child.agentName,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '${child.durationLabel}  ·  ${child.totalRounds}r  ·  ${child.model ?? "unknown"}',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: roleColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                roleLabel,
                style: TextStyle(fontSize: 10, color: roleColor, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 16, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }

  Widget _buildLlmCallCard(TraceSpan span, List<TraceSpan> toolCalls, int roundNum) {
    final outputData = span.outputDataJson;
    final inputData = span.inputDataJson;
    final messages = inputData?['messages'] as List<dynamic>?;
    final responseText = outputData?['text'] as String?;
    final stopReason = outputData?['stopReason'] as String?;

    return _StepCard(
      icon: Icons.psychology,
      iconColor: Colors.indigo,
      lineColor: Colors.indigo.shade200,
      title: 'Round $roundNum — ${span.name ?? "LLM Call"}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (span.model != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.indigo.shade200),
              ),
              child: Text(
                span.model!,
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.indigo.shade700,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            span.durationLabel,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Prompt summary (collapsible)
          if (messages != null)
            _PromptViewer(messages: messages),

          // Response
          if (responseText != null && responseText.isNotEmpty) ...[
            const SizedBox(height: 8),
            _label('Model Response:'),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                responseText.length > 800
                    ? '${responseText.substring(0, 800)}...'
                    : responseText,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],

          // Stop reason
          if (stopReason != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                _label('Stop reason: '),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _stopReasonColor(stopReason).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    stopReason,
                    style: TextStyle(
                      fontSize: 11,
                      color: _stopReasonColor(stopReason),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],

          // Tool calls nested inside
          if (toolCalls.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            ...toolCalls.map((tc) => _buildToolCallCard(tc)),
          ],
        ],
      ),
    );
  }

  Widget _buildToolCallCard(TraceSpan span) {
    final inputData = span.inputDataJson;
    final outputData = span.outputDataJson;
    final arguments = inputData?['arguments'];
    final result = outputData?['result'] as String?;

    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 8),
      child: _StepCard(
        icon: Icons.build,
        iconColor: Colors.purple,
        lineColor: Colors.purple.shade200,
        compact: true,
        title: span.name ?? 'Tool Call',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              span.durationLabel,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
            const SizedBox(width: 4),
            Icon(
              span.status == 'completed' ? Icons.check_circle : Icons.error,
              size: 14,
              color: span.status == 'completed' ? Colors.green : Colors.red,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (arguments != null) ...[
              _label('Arguments:'),
              _codeBlock(_prettyJson(arguments)),
            ],
            if (result != null) ...[
              const SizedBox(height: 4),
              _label('Result:'),
              _codeBlock(
                result.length > 500 ? '${result.substring(0, 500)}...' : result,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCollapsibleSection({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String content,
    bool defaultExpanded = false,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: Icon(icon, color: iconColor, size: 20),
        title: Text(title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        initiallyExpanded: defaultExpanded,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _codeBlock(content),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard(String error) {
    return Card(
      color: Colors.red.shade50,
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.error, color: Colors.red, size: 18),
                const SizedBox(width: 8),
                Text('Error',
                    style: TextStyle(
                        color: Colors.red.shade700,
                        fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              error,
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Colors.red.shade900),
            ),
          ],
        ),
      ),
    );
  }

  Icon _statusIcon(InferenceStatus status) {
    switch (status) {
      case InferenceStatus.inProgress:
        return const Icon(Icons.hourglass_top, color: Colors.orange);
      case InferenceStatus.completed:
        return const Icon(Icons.check_circle, color: Colors.green);
      case InferenceStatus.error:
        return const Icon(Icons.error, color: Colors.red);
      case InferenceStatus.cancelled:
        return const Icon(Icons.cancel, color: Colors.grey);
    }
  }

  Widget _label(String text) {
    return Text(
      text,
      style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Colors.grey.shade600),
    );
  }

  Widget _codeBlock(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(4),
      ),
      child: SelectableText(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
      ),
    );
  }

  Color _modeColor(String? mode) {
    switch (mode) {
      case 'local_multi_round': return Colors.indigo;
      case 'local_single_round': return Colors.blue;
      case 'remote_acp': return Colors.teal;
      case 'group_orchestration': return Colors.deepOrange;
      case 'group_plan': return Colors.amber.shade800;
      case 'group_flow': return Colors.green.shade700;
      case 'group_local': return Colors.purple;
      case 'group_remote_acp': return Colors.cyan.shade700;
      default: return Colors.grey;
    }
  }

  Color _stopReasonColor(String reason) {
    switch (reason) {
      case 'stop': return Colors.green;
      case 'tool_calls': return Colors.purple;
      case 'error': return Colors.red;
      default: return Colors.grey;
    }
  }

  String _prettyJson(dynamic data) {
    try {
      return const JsonEncoder.withIndent('  ').convert(data);
    } catch (_) {
      return data.toString();
    }
  }

  Widget _chip(String label, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: fg, fontWeight: FontWeight.w600)),
    );
  }
}

// =============================================================================
// Helper widgets
// =============================================================================

/// A card with a left-side connector line — creates the stepper look.
class _StepCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color lineColor;
  final String title;
  final Widget? trailing;
  final Widget child;
  final bool compact;

  const _StepCard({
    required this.icon,
    required this.iconColor,
    required this.lineColor,
    required this.title,
    required this.child,
    this.trailing,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Left connector
          SizedBox(
            width: 32,
            child: Column(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                    border: Border.all(color: iconColor.withValues(alpha: 0.4)),
                  ),
                  child: Icon(icon, size: 14, color: iconColor),
                ),
                Expanded(
                  child: Center(
                    child: Container(
                      width: 2,
                      color: lineColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Content
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(12, compact ? 8 : 10, 12, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: compact ? 12 : 13,
                              fontWeight: FontWeight.w600,
                              color: iconColor,
                            ),
                          ),
                        ),
                        if (trailing != null) trailing!,
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(12, 0, 12, compact ? 8 : 10),
                    child: child,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Collapsible prompt viewer: shows "N messages" summary, expands to full JSON.
class _PromptViewer extends StatefulWidget {
  final List<dynamic> messages;

  const _PromptViewer({required this.messages});

  @override
  State<_PromptViewer> createState() => _PromptViewerState();
}

class _PromptViewerState extends State<_PromptViewer> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final count = widget.messages.length;
    final summary = '$count message${count == 1 ? '' : 's'} in prompt';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: Colors.indigo,
                ),
                const SizedBox(width: 4),
                Text(
                  summary,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.indigo,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 300),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(4),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                const JsonEncoder.withIndent('  ').convert(widget.messages),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
