import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../l10n/app_localizations.dart';
import '../models/inference_log_entry.dart';
import '../services/inference_log_service.dart';
import 'channel_trace_screen.dart';

class InferenceLogScreen extends StatefulWidget {
  final bool embedded;

  const InferenceLogScreen({Key? key, this.embedded = false}) : super(key: key);

  @override
  State<InferenceLogScreen> createState() => _InferenceLogScreenState();
}

class _InferenceLogScreenState extends State<InferenceLogScreen> {
  final _service = InferenceLogService.instance;
  InferenceStatus? _statusFilter;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  List<InferenceLogEntry> get _filteredEntries {
    if (_statusFilter == null) return _service.entries;
    return _service.entries.where((e) => e.status == _statusFilter).toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final entries = _filteredEntries;
    final allEntries = _service.entries;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: widget.embedded ? null : Text(l10n.inferenceLog_title),
        actions: [
          // Status filter
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
            ],
          ),

          // More actions
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
                const PopupMenuItem(
                  value: 'persisted',
                  child: ListTile(
                    leading: Icon(Icons.psychology),
                    title: Text('Persisted Traces (SQLite)'),
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
                      _service.enabled
                          ? Icons.toggle_on
                          : Icons.toggle_off,
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
          // Stats bar
          Container(
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem(
                  l10n.inferenceLog_total,
                  allEntries.length,
                  Colors.blue,
                ),
                _buildStatItem(
                  l10n.inferenceLog_completed,
                  allEntries
                      .where((e) => e.status == InferenceStatus.completed)
                      .length,
                  Colors.green,
                ),
                _buildStatItem(
                  l10n.inferenceLog_errors,
                  allEntries
                      .where((e) => e.status == InferenceStatus.error)
                      .length,
                  Colors.red,
                ),
                _buildStatItem(
                  l10n.inferenceLog_inProgress,
                  allEntries
                      .where((e) => e.status == InferenceStatus.inProgress)
                      .length,
                  Colors.orange,
                ),
              ],
            ),
          ),

          // List
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.psychology_outlined,
                            size: 64, color: Colors.grey.shade400),
                        const SizedBox(height: 16),
                        Text(l10n.inferenceLog_empty,
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 16,
                            )),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(
                            l10n.inferenceLog_emptyHint,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) =>
                        _buildLogCard(entries[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, int count, Color color) {
    return Column(
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
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  Widget _buildLogCard(InferenceLogEntry entry) {
    final l10n = AppLocalizations.of(context);
    final timeStr = _formatTime(entry.startTime);
    final subtitle =
        '$timeStr - ${entry.durationLabel} - ${l10n.inferenceLog_rounds(entry.rounds.length)} - ${l10n.inferenceLog_toolCalls(entry.totalToolCalls)}';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ExpansionTile(
        leading: _statusIcon(entry.status),
        title: Text(
          '${entry.agentName} - ${entry.model ?? "unknown"}',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        children: [
          _buildExpandedContent(entry),
        ],
      ),
    );
  }

  Widget _buildExpandedContent(InferenceLogEntry entry) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // User message
          _sectionLabel(l10n.inferenceLog_userMessage),
          _codeBlock(entry.userMessage),

          // Rounds
          for (final round in entry.rounds) ...[
            const SizedBox(height: 8),
            _sectionLabel(l10n.inferenceLog_roundLabel(round.roundNumber)),
            if (round.textBuffer.isNotEmpty)
              _codeBlock(round.textBuffer.toString())
            else
              _codeBlock(l10n.inferenceLog_noText),

            for (final tc in round.toolCalls) ...[
              const SizedBox(height: 4),
              _sectionLabel(l10n.inferenceLog_toolCall(tc['name'] as String)),
              _codeBlock(_prettyJson(tc['arguments'])),
            ],

            for (final tr in round.toolResults) ...[
              const SizedBox(height: 4),
              _sectionLabel(
                  l10n.inferenceLog_toolResult(tr['name'] as String)),
              _codeBlock(tr['result'] as String? ?? ''),
            ],

            if (round.stopReason != null) ...[
              const SizedBox(height: 4),
              _sectionLabel(
                  '${l10n.inferenceLog_stopReason}: ${round.stopReason}'),
            ],
          ],

          // Error
          if (entry.errorMessage != null) ...[
            const SizedBox(height: 8),
            _sectionLabel(l10n.inferenceLog_error),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(
                entry.errorMessage!,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Colors.red.shade900,
                ),
              ),
            ),
          ],

          // View details button
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
          color: Colors.grey.shade700,
        ),
      ),
    );
  }

  Widget _codeBlock(String text) {
    final displayText =
        text.length > 500 ? '${text.substring(0, 500)}...' : text;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(4),
      ),
      child: SelectableText(
        displayText,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Detail view
  // ---------------------------------------------------------------------------

  void _showDetail(InferenceLogEntry entry) {
    final l10n = AppLocalizations.of(context);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _InferenceDetailScreen(entry: entry, l10n: l10n),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

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
      final json = _service.exportAsJson();
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

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

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
    return '${dt.hour.toString().padLeft(2, '0')}:'
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

// =============================================================================
// Detail screen (full page)
// =============================================================================

class _InferenceDetailScreen extends StatelessWidget {
  final InferenceLogEntry entry;
  final AppLocalizations l10n;

  const _InferenceDetailScreen({required this.entry, required this.l10n});

  @override
  Widget build(BuildContext context) {
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
          // Header
          _header(context),
          const Divider(height: 24),

          // System prompt
          if (entry.systemPrompt != null && entry.systemPrompt!.isNotEmpty) ...[
            _label(l10n.inferenceLog_systemPrompt),
            _block(entry.systemPrompt!),
            const Divider(height: 24),
          ],

          // User message
          _label(l10n.inferenceLog_userMessage),
          _block(entry.userMessage),
          const Divider(height: 24),

          // Rounds
          for (final round in entry.rounds) ...[
            _label(l10n.inferenceLog_roundLabel(round.roundNumber)),
            if (round.textBuffer.isNotEmpty)
              _block(round.textBuffer.toString())
            else
              _block(l10n.inferenceLog_noText),

            for (final tc in round.toolCalls) ...[
              const SizedBox(height: 8),
              _label(l10n.inferenceLog_toolCall(tc['name'] as String)),
              _block(_prettyJson(tc['arguments'])),
            ],

            for (final tr in round.toolResults) ...[
              const SizedBox(height: 8),
              _label(l10n.inferenceLog_toolResult(tr['name'] as String)),
              _block(tr['result'] as String? ?? ''),
            ],

            if (round.stopReason != null) ...[
              const SizedBox(height: 4),
              _label('${l10n.inferenceLog_stopReason}: ${round.stopReason}'),
            ],
            const Divider(height: 24),
          ],

          // Error
          if (entry.errorMessage != null) ...[
            _label(l10n.inferenceLog_error),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(
                entry.errorMessage!,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Colors.red.shade900,
                ),
              ),
            ),
            const Divider(height: 24),
          ],

          // Timeline
          _label(l10n.inferenceLog_timeline),
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
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
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
                    child: Text(
                      event.data.entries
                          .map((e) => '${e.key}: ${e.value}')
                          .join(', '),
                      style:
                          const TextStyle(fontFamily: 'monospace', fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _statusIcon(entry.status),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${entry.agentName} - ${entry.model ?? "unknown"}',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'ID: ${entry.id}',
          style: TextStyle(
              fontSize: 11, color: Colors.grey.shade500, fontFamily: 'monospace'),
        ),
        Text(
          'Provider: ${entry.provider ?? "—"}  |  Duration: ${entry.durationLabel}',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        Text(
          'Rounds: ${entry.rounds.length}  |  Tool calls: ${entry.totalToolCalls}  |  Text: ${entry.totalTextChars} chars',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
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

  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, top: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Colors.grey.shade700,
        ),
      ),
    );
  }

  Widget _block(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
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
