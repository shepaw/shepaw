import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../l10n/app_localizations.dart';
import '../models/inference_log_entry.dart';
import '../models/trace_models.dart';
import '../services/inference_log_catalog.dart';
import '../services/inference_log_service.dart';
import '../services/trace_service.dart';
import 'channel_trace_screen.dart';

class InferenceLogScreen extends StatefulWidget {
  final bool embedded;

  const InferenceLogScreen({Key? key, this.embedded = false}) : super(key: key);

  @override
  State<InferenceLogScreen> createState() => _InferenceLogScreenState();
}

class _InferenceLogScreenState extends State<InferenceLogScreen> {
  final _service = InferenceLogService.instance;
  final _trace = TraceService.instance;
  final _searchController = TextEditingController();

  InferenceStatus? _statusFilter;
  bool _problemsOnly = false;
  List<TraceEntry> _persisted = [];
  Timer? _persistPoll;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChanged);
    _trace.addListener(_onChanged);
    _searchController.addListener(_onChanged);
    _loadPersisted();
    _persistPoll =
        Timer.periodic(const Duration(seconds: 3), (_) => _loadPersisted());
  }

  @override
  void dispose() {
    _persistPoll?.cancel();
    _service.removeListener(_onChanged);
    _trace.removeListener(_onChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadPersisted() async {
    final traces = await _trace.queryTraces(limit: 200);
    if (!mounted) return;
    setState(() => _persisted = traces);
  }

  List<InferenceLogRow> get _allRows => InferenceLogCatalog.merge(
        live: _service.entries,
        persisted: _persisted,
      );

  List<InferenceLogRow> get _filteredRows => InferenceLogCatalog.filter(
        _allRows,
        status: _statusFilter,
        query: _searchController.text,
        problemsOnly: _problemsOnly,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final rows = _filteredRows;
    final allRows = _allRows;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: widget.embedded ? null : Text(l10n.inferenceLog_title),
        actions: [
          PopupMenuButton<InferenceStatus?>(
            icon: const Icon(Icons.filter_list),
            initialValue: _statusFilter,
            onSelected: (value) => setState(() => _statusFilter = value),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: null,
                child: Text(l10n.inferenceLog_filterAll),
              ),
              PopupMenuItem(
                value: InferenceStatus.completed,
                child: Text(l10n.inferenceLog_filterCompleted),
              ),
              PopupMenuItem(
                value: InferenceStatus.error,
                child: Text(l10n.inferenceLog_filterError),
              ),
              PopupMenuItem(
                value: InferenceStatus.inProgress,
                child: Text(l10n.inferenceLog_filterInProgress),
              ),
              PopupMenuItem(
                value: InferenceStatus.cancelled,
                child: Text(l10n.inferenceLog_filterCancelled),
              ),
            ],
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'export':
                  _exportLogs();
                  break;
                case 'clear':
                  _clearLogs();
                  break;
                case 'toggle':
                  _toggleLogging();
                  break;
                case 'persisted':
                  _viewPersistedTraces();
                  break;
              }
            },
            itemBuilder: (context) {
              final menuL10n = AppLocalizations.of(context);
              return [
                PopupMenuItem(
                  value: 'persisted',
                  child: ListTile(
                    leading: const Icon(Icons.psychology),
                    title: Text(menuL10n.inferenceLog_persistedTraces),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'export',
                  child: ListTile(
                    leading: const Icon(Icons.share),
                    title: Text(menuL10n.log_export),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'clear',
                  child: ListTile(
                    leading: const Icon(Icons.delete, color: Colors.red),
                    title: Text(menuL10n.inferenceLog_clearTitle,
                        style: const TextStyle(color: Colors.red)),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'toggle',
                  child: ListTile(
                    leading: Icon(
                      _service.enabled ? Icons.toggle_on : Icons.toggle_off,
                      color: _service.enabled ? Colors.green : Colors.grey,
                    ),
                    title: Text(_service.enabled
                        ? menuL10n.inferenceLog_loggingEnabled
                        : menuL10n.inferenceLog_loggingDisabled),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: l10n.inferenceLog_searchHint,
                border: const OutlineInputBorder(),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: _searchController.clear,
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilterChip(
                label: Text(l10n.inferenceLog_problemsOnly),
                selected: _problemsOnly,
                avatar: Icon(
                  Icons.report_problem_outlined,
                  size: 16,
                  color: _problemsOnly
                      ? Theme.of(context).colorScheme.onSecondaryContainer
                      : Colors.red,
                ),
                onSelected: (v) => setState(() => _problemsOnly = v),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem(
                  l10n.inferenceLog_total,
                  allRows.length,
                  Colors.blue,
                  selected: _statusFilter == null && !_problemsOnly,
                  onTap: () => setState(() {
                    _statusFilter = null;
                    _problemsOnly = false;
                  }),
                ),
                _buildStatItem(
                  l10n.inferenceLog_completed,
                  allRows
                      .where((e) => e.status == InferenceStatus.completed)
                      .length,
                  Colors.green,
                  selected: _statusFilter == InferenceStatus.completed,
                  onTap: () => setState(() {
                    _problemsOnly = false;
                    _statusFilter = InferenceStatus.completed;
                  }),
                ),
                _buildStatItem(
                  l10n.inferenceLog_errors,
                  allRows.where((e) => e.isProblem).length,
                  Colors.red,
                  selected: _statusFilter == InferenceStatus.error ||
                      _problemsOnly,
                  onTap: () => setState(() {
                    _problemsOnly = true;
                    _statusFilter = null;
                  }),
                ),
                _buildStatItem(
                  l10n.inferenceLog_inProgress,
                  allRows
                      .where((e) => e.status == InferenceStatus.inProgress)
                      .length,
                  Colors.orange,
                  selected: _statusFilter == InferenceStatus.inProgress,
                  onTap: () => setState(() {
                    _problemsOnly = false;
                    _statusFilter = InferenceStatus.inProgress;
                  }),
                ),
              ],
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? _buildEmpty(l10n, hasSource: allRows.isNotEmpty)
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) =>
                        _buildLogCard(rows[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(AppLocalizations l10n, {required bool hasSource}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.psychology_outlined,
                size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              hasSource ? l10n.inferenceLog_noMatch : l10n.inferenceLog_empty,
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              hasSource
                  ? l10n.inferenceLog_noMatchHint
                  : l10n.inferenceLog_emptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(
    String label,
    int count,
    Color color, {
    bool selected = false,
    VoidCallback? onTap,
  }) {
    final child = Column(
      children: [
        Text(
          count.toString(),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
          ),
        ),
      ],
    );
    if (onTap == null) return child;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: child,
      ),
    );
  }

  Widget _buildLogCard(InferenceLogRow row) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final timeStr = _formatTime(row.startTime);
    final mode = row.executionMode ?? row.traceRole;
    final subtitleBits = <String>[
      timeStr,
      row.durationLabel,
      l10n.inferenceLog_rounds(row.rounds),
      l10n.inferenceLog_toolCalls(row.toolCalls),
      if (mode != null && mode.isNotEmpty) mode,
    ];
    final live = row.live;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: row.isProblem
                  ? Colors.red
                  : row.status == InferenceStatus.inProgress
                      ? Colors.orange
                      : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: live != null
            ? ExpansionTile(
                leading: _statusIcon(row.status),
                title: Text(
                  '${row.agentName} — ${row.model ?? "unknown"}',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subtitleBits.join(' · '),
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                    if (row.userMessage.isNotEmpty)
                      Text(
                        row.userMessage,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    if (row.isProblem && row.errorMessage != null)
                      Text(
                        row.errorMessage!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.error,
                          fontFamily: 'monospace',
                        ),
                      ),
                  ],
                ),
                children: [
                  _buildExpandedContent(live),
                ],
              )
            : ListTile(
                leading: _statusIcon(row.status),
                title: Text(
                  '${row.agentName} — ${row.model ?? "unknown"}',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subtitleBits.join(' · '),
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                    if (row.userMessage.isNotEmpty)
                      Text(
                        row.userMessage,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    if (row.isProblem && row.errorMessage != null)
                      Text(
                        row.errorMessage!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.error,
                          fontFamily: 'monospace',
                        ),
                      ),
                  ],
                ),
                isThreeLine: true,
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => _openRow(row),
              ),
      ),
    );
  }

  Widget _buildExpandedContent(InferenceLogEntry entry) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(l10n.inferenceLog_userMessage),
          _codeBlock(entry.userMessage),
          for (final round in entry.rounds) ...[
            const SizedBox(height: 8),
            _sectionLabel(l10n.inferenceLog_roundLabel(round.roundNumber)),
            if (round.textBuffer.isNotEmpty)
              _codeBlock(round.textBuffer.toString())
            else
              _codeBlock(l10n.inferenceLog_noText),
            for (final tc in round.toolCalls) ...[
              const SizedBox(height: 4),
              _sectionLabel(l10n.inferenceLog_toolCall(_toolName(tc))),
              _codeBlock(_prettyJson(tc['arguments'])),
            ],
            for (final tr in round.toolResults) ...[
              const SizedBox(height: 4),
              _sectionLabel(l10n.inferenceLog_toolResult(_toolName(tr))),
              _codeBlock(tr['result']?.toString() ?? ''),
            ],
            if (round.stopReason != null) ...[
              const SizedBox(height: 4),
              _sectionLabel(
                  '${l10n.inferenceLog_stopReason}: ${round.stopReason}'),
            ],
          ],
          if (entry.errorMessage != null) ...[
            const SizedBox(height: 8),
            _sectionLabel(l10n.inferenceLog_error),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(
                entry.errorMessage!,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _showDetail(entry),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(l10n.widget_details),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, top: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _codeBlock(String text) {
    final scheme = Theme.of(context).colorScheme;
    final displayText =
        text.length > 800 ? '${text.substring(0, 800)}...' : text;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: SelectableText(
        displayText,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }

  void _openRow(InferenceLogRow row) {
    if (row.live != null) {
      _showDetail(row.live!);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TraceDetailScreen(traceId: row.id),
      ),
    );
  }

  void _showDetail(InferenceLogEntry entry) {
    final l10n = AppLocalizations.of(context);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _InferenceDetailScreen(entry: entry, l10n: l10n),
      ),
    );
  }

  void _viewPersistedTraces() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const ChannelTraceScreen(channelName: 'All Channels'),
      ),
    );
  }

  Future<void> _exportLogs() async {
    final l10n = AppLocalizations.of(context);
    try {
      final payload = _allRows
          .map((row) => row.live?.toJson() ?? row.persisted?.toJson() ?? {'id': row.id})
          .toList();
      final json = const JsonEncoder.withIndent('  ').convert(payload);
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/inference_logs_${DateTime.now().millisecondsSinceEpoch}.json');
      await file.writeAsString(json);
      await Share.shareXFiles([XFile(file.path)], subject: 'Inference Logs');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.inferenceLog_exported)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.inferenceLog_exportFailed('$e')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _clearLogs() async {
    final l10n = AppLocalizations.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        final dialogL10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(dialogL10n.inferenceLog_clearTitle),
          content: Text(dialogL10n.inferenceLog_clearContent),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(dialogL10n.common_cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text(dialogL10n.inferenceLog_clearButton),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      _service.clearAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.inferenceLog_cleared)),
        );
      }
    }
  }

  void _toggleLogging() {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _service.enabled = !_service.enabled;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_service.enabled
            ? l10n.inferenceLog_loggingEnabled
            : l10n.inferenceLog_loggingDisabled),
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

  String _formatTime(DateTime dt) {
    return '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  String _prettyJson(dynamic data) {
    try {
      return const JsonEncoder.withIndent('  ').convert(data);
    } catch (_) {
      return data.toString();
    }
  }
}

String _toolName(Map<String, dynamic> data) {
  final name = data['name'];
  if (name == null) return 'unknown';
  return name.toString();
}

class _InferenceDetailScreen extends StatelessWidget {
  final InferenceLogEntry entry;
  final AppLocalizations l10n;

  const _InferenceDetailScreen({required this.entry, required this.l10n});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.inferenceLog_detailTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: l10n.common_copy,
            onPressed: () {
              final json =
                  const JsonEncoder.withIndent('  ').convert(entry.toJson());
              Clipboard.setData(ClipboardData(text: json));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.chat_copiedToClipboard)),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _header(context),
          const Divider(height: 24),
          if (entry.systemPrompt != null && entry.systemPrompt!.isNotEmpty) ...[
            _label(context, l10n.inferenceLog_systemPrompt),
            _block(context, entry.systemPrompt!),
            const Divider(height: 24),
          ],
          _label(context, l10n.inferenceLog_userMessage),
          _block(context, entry.userMessage),
          const Divider(height: 24),
          for (final round in entry.rounds) ...[
            _label(context, l10n.inferenceLog_roundLabel(round.roundNumber)),
            if (round.textBuffer.isNotEmpty)
              _block(context, round.textBuffer.toString())
            else
              _block(context, l10n.inferenceLog_noText),
            for (final tc in round.toolCalls) ...[
              const SizedBox(height: 8),
              _label(context, l10n.inferenceLog_toolCall(_toolName(tc))),
              _block(context, _prettyJson(tc['arguments'])),
            ],
            for (final tr in round.toolResults) ...[
              const SizedBox(height: 8),
              _label(context, l10n.inferenceLog_toolResult(_toolName(tr))),
              _block(context, tr['result']?.toString() ?? ''),
            ],
            if (round.stopReason != null) ...[
              const SizedBox(height: 4),
              _label(context,
                  '${l10n.inferenceLog_stopReason}: ${round.stopReason}'),
            ],
            const Divider(height: 24),
          ],
          if (entry.errorMessage != null) ...[
            _label(context, l10n.inferenceLog_error),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(
                entry.errorMessage!,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
            const Divider(height: 24),
          ],
          _label(context, l10n.inferenceLog_timeline),
          for (final event in entry.timeline)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 70,
                    child: Text(
                      _formatTime(event.timestamp),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: _timelineColor(event.type).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      event.type,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _timelineColor(event.type),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SelectableText(
                      event.data.entries
                          .map((e) => '${e.key}: ${e.value}')
                          .join(', '),
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _statusIcon(entry.status),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${entry.agentName} — ${entry.model ?? "unknown"}',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'ID: ${entry.id}',
          style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant,
              fontFamily: 'monospace'),
        ),
        Text(
          'Provider: ${entry.provider ?? "—"}  |  '
          '${entry.executionMode ?? "—"}  |  Duration: ${entry.durationLabel}',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        Text(
          'Rounds: ${entry.rounds.length}  |  Tool calls: ${entry.totalToolCalls}  |  Text: ${entry.totalTextChars} chars'
          '${entry.totalInputTokens + entry.totalOutputTokens > 0 ? '  |  Tokens: ${entry.totalInputTokens}→${entry.totalOutputTokens}' : ''}',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
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

  Widget _label(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, top: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _block(BuildContext context, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: SelectableText(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }

  Color _timelineColor(String type) {
    switch (type) {
      case 'request':
        return Colors.blue;
      case 'tool_call':
        return Colors.purple;
      case 'tool_result':
        return Colors.teal;
      case 'done':
        return Colors.green;
      case 'error':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}.'
        '${dt.millisecond.toString().padLeft(3, '0')}';
  }

  String _prettyJson(dynamic data) {
    try {
      return const JsonEncoder.withIndent('  ').convert(data);
    } catch (_) {
      return data.toString();
    }
  }
}
