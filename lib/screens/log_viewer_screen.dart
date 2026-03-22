import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../l10n/app_localizations.dart';
import '../services/logger_service.dart';

/// 日志查看器界面
///
/// P1: 提供日志查看和导出功能
class LogViewerScreen extends StatefulWidget {
  final bool embedded;

  const LogViewerScreen({Key? key, this.embedded = false}) : super(key: key);

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  final _logger = LoggerService();
  List<LogEntry> _logs = [];
  LogLevel? _selectedLevel;
  String? _selectedTag;
  bool _autoScroll = true;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _loadLogs() {
    setState(() {
      _logs = _logger.getMemoryLogs(level: _selectedLevel, tag: _selectedTag);
      if (_autoScroll && _logs.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
          }
        });
      }
    });
  }

  Future<void> _exportLogs() async {
    final l10n = AppLocalizations.of(context);
    final path = await _logger.exportLogs();
    if (path != null && mounted) {
      await Share.shareXFiles(
        [XFile(path)],
        subject: 'Paw Logs',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.log_exported)),
        );
      }
    }
  }

  Future<void> _clearLogs() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        final dialogL10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(dialogL10n.log_clearTitle),
          content: Text(dialogL10n.log_clearContent),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(dialogL10n.common_cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text(dialogL10n.log_clearButton),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      await _logger.clearOldLogs(daysToKeep: 0);
      _loadLogs();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: widget.embedded ? null : Text(l10n.log_title),
        actions: [
          // Tag 筛选
          PopupMenuButton<String?>(
            icon: const Icon(Icons.label_outline),
            tooltip: 'Filter by tag',
            initialValue: _selectedTag,
            onSelected: (tag) {
              setState(() {
                _selectedTag = tag;
                _loadLogs();
              });
            },
            itemBuilder: (context) {
              final tags = _logger.getUsedTags();
              return [
                const PopupMenuItem(
                  value: null,
                  child: Text('All Tags'),
                ),
                ...tags.map((tag) => PopupMenuItem(
                      value: tag,
                      child: Text(tag),
                    )),
              ];
            },
          ),

          // 日志级别筛选
          PopupMenuButton<LogLevel?>(
            icon: const Icon(Icons.filter_list),
            tooltip: l10n.log_filterTooltip,
            initialValue: _selectedLevel,
            onSelected: (level) {
              setState(() {
                _selectedLevel = level;
                _loadLogs();
              });
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: null,
                child: Text(l10n.log_all),
              ),
              const PopupMenuItem(
                value: LogLevel.debug,
                child: Text('Debug'),
              ),
              const PopupMenuItem(
                value: LogLevel.info,
                child: Text('Info'),
              ),
              const PopupMenuItem(
                value: LogLevel.warning,
                child: Text('Warning'),
              ),
              const PopupMenuItem(
                value: LogLevel.error,
                child: Text('Error'),
              ),
            ],
          ),

          // 自动滚动开关
          IconButton(
            icon: Icon(_autoScroll ? Icons.lock_open : Icons.lock),
            tooltip: _autoScroll ? l10n.log_disableAutoScroll : l10n.log_enableAutoScroll,
            onPressed: () {
              setState(() => _autoScroll = !_autoScroll);
            },
          ),

          // 更多操作
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'export':
                  _exportLogs();
                  break;
                case 'clear':
                  _clearLogs();
                  break;
                case 'refresh':
                  _loadLogs();
                  break;
              }
            },
            itemBuilder: (context) {
              final menuL10n = AppLocalizations.of(context);
              return [
                PopupMenuItem(
                  value: 'refresh',
                  child: ListTile(
                    leading: const Icon(Icons.refresh),
                    title: Text(menuL10n.common_refresh),
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
                    title: Text(menuL10n.log_clearTitle, style: const TextStyle(color: Colors.red)),
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
          // Active filter chips
          if (_selectedLevel != null || _selectedTag != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  if (_selectedLevel != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Chip(
                        label: Text(_selectedLevel!.toString().split('.').last.toUpperCase()),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () {
                          setState(() {
                            _selectedLevel = null;
                            _loadLogs();
                          });
                        },
                      ),
                    ),
                  if (_selectedTag != null)
                    Chip(
                      avatar: const Icon(Icons.label_outline, size: 16),
                      label: Text(_selectedTag!),
                      deleteIcon: const Icon(Icons.close, size: 16),
                      onDeleted: () {
                        setState(() {
                          _selectedTag = null;
                          _loadLogs();
                        });
                      },
                    ),
                ],
              ),
            ),

          // 统计信息栏
          Container(
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem(l10n.log_total, _logs.length, Colors.blue),
                _buildStatItem(
                  'Error',
                  _logs.where((l) => l.level == LogLevel.error).length,
                  Colors.red,
                ),
                _buildStatItem(
                  'Warning',
                  _logs.where((l) => l.level == LogLevel.warning).length,
                  Colors.orange,
                ),
                _buildStatItem(
                  'Info',
                  _logs.where((l) => l.level == LogLevel.info).length,
                  Colors.green,
                ),
              ],
            ),
          ),

          // 日志列表
          Expanded(
            child: _logs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.article_outlined,
                          size: 64,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          l10n.log_noLogs,
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: _logs.length,
                    itemBuilder: (context, index) {
                      return _buildLogItem(_logs[index]);
                    },
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
        Text(
          label,
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildLogItem(LogEntry log) {
    final tagLabel = log.tag != null ? ' [${log.tag}]' : '';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ExpansionTile(
        leading: _getLogIcon(log.level),
        title: Text(
          log.message,
          style: const TextStyle(fontSize: 14),
        ),
        subtitle: Text(
          '${log.timeString} • ${log.levelString}$tagLabel',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        children: [
          if (log.error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SelectableText(
                  'Error: ${log.error}',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Colors.red.shade900,
                  ),
                ),
              ),
            ),
          if (log.stackTrace != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SelectableText(
                  log.stackTrace.toString(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Icon _getLogIcon(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return const Icon(Icons.bug_report, color: Colors.grey);
      case LogLevel.info:
        return const Icon(Icons.info_outline, color: Colors.blue);
      case LogLevel.warning:
        return const Icon(Icons.warning_amber, color: Colors.orange);
      case LogLevel.error:
        return const Icon(Icons.error_outline, color: Colors.red);
    }
  }
}
