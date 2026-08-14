import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../l10n/app_localizations.dart';
import '../services/log_file_parser.dart';
import '../services/logger_service.dart';

/// 日志查看器：合并内存与落盘日志，突出错误/警告，便于定位用户问题。
class LogViewerScreen extends StatefulWidget {
  final bool embedded;

  const LogViewerScreen({Key? key, this.embedded = false}) : super(key: key);

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  final _logger = LoggerService();
  final _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<LogEntry> _allLogs = [];
  List<LogEntry> _logs = [];
  LogLevel? _minLevel;
  String? _selectedTag;
  bool _problemsOnly = false;
  bool _loading = true;
  Timer? _diskPoll;

  @override
  void initState() {
    super.initState();
    _logger.addListener(_onLoggerChanged);
    _searchController.addListener(_applyFilter);
    _loadLogs();
    _diskPoll = Timer.periodic(const Duration(seconds: 3), (_) => _loadLogs());
  }

  @override
  void dispose() {
    _diskPoll?.cancel();
    _logger.removeListener(_onLoggerChanged);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onLoggerChanged() => _loadLogs();

  Future<void> _loadLogs() async {
    final merged = await _logger.getDisplayLogs();
    if (!mounted) return;
    setState(() {
      _allLogs = merged;
      _loading = false;
      _applyFilter(notify: false);
    });
  }

  void _applyFilter({bool notify = true}) {
    final filtered = LogCatalog.filter(
      _allLogs,
      minLevel: _minLevel,
      tag: _selectedTag,
      query: _searchController.text,
      problemsOnly: _problemsOnly,
    );
    if (notify) {
      setState(() => _logs = filtered);
    } else {
      _logs = filtered;
    }
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
      await _logger.clearAllLogs();
      await _loadLogs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).log_cleared)),
        );
      }
    }
  }

  void _copyLog(LogEntry log) {
    Clipboard.setData(ClipboardData(text: log.copyText));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).log_copied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tags = LoggerService.tagsOf(_allLogs);
    final errorCount = _allLogs.where((l) => l.level == LogLevel.error).length;
    final warningCount =
        _allLogs.where((l) => l.level == LogLevel.warning).length;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: widget.embedded ? null : Text(l10n.log_title),
        actions: [
          PopupMenuButton<String?>(
            icon: const Icon(Icons.label_outline),
            tooltip: l10n.log_filterByTag,
            initialValue: _selectedTag,
            onSelected: (tag) {
              setState(() {
                _selectedTag = tag;
                _applyFilter(notify: false);
              });
            },
            itemBuilder: (context) {
              return [
                PopupMenuItem(
                  value: null,
                  child: Text(l10n.log_allTags),
                ),
                ...tags.map((tag) => PopupMenuItem(
                      value: tag,
                      child: Text(tag),
                    )),
              ];
            },
          ),
          PopupMenuButton<LogLevel?>(
            icon: const Icon(Icons.filter_list),
            tooltip: l10n.log_filterTooltip,
            initialValue: _minLevel,
            onSelected: (level) {
              setState(() {
                _minLevel = level;
                _applyFilter(notify: false);
              });
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: null,
                child: Text(l10n.log_all),
              ),
              PopupMenuItem(
                value: LogLevel.debug,
                child: Text(l10n.log_levelDebug),
              ),
              PopupMenuItem(
                value: LogLevel.info,
                child: Text(l10n.log_levelInfo),
              ),
              PopupMenuItem(
                value: LogLevel.warning,
                child: Text(l10n.log_levelWarning),
              ),
              PopupMenuItem(
                value: LogLevel.error,
                child: Text(l10n.log_levelError),
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
                    title: Text(menuL10n.log_clearTitle,
                        style: const TextStyle(color: Colors.red)),
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
                hintText: l10n.log_searchHint,
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
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilterChip(
                  label: Text(l10n.log_problemsOnly),
                  selected: _problemsOnly,
                  avatar: Icon(
                    Icons.report_problem_outlined,
                    size: 16,
                    color: _problemsOnly
                        ? Theme.of(context).colorScheme.onSecondaryContainer
                        : Colors.orange,
                  ),
                  onSelected: (v) {
                    setState(() {
                      _problemsOnly = v;
                      _applyFilter(notify: false);
                    });
                  },
                ),
                if (_minLevel != null)
                  InputChip(
                    label: Text(_minLevel!.name.toUpperCase()),
                    onDeleted: () {
                      setState(() {
                        _minLevel = null;
                        _applyFilter(notify: false);
                      });
                    },
                  ),
                if (_selectedTag != null)
                  InputChip(
                    avatar: const Icon(Icons.label_outline, size: 16),
                    label: Text(_selectedTag!),
                    onDeleted: () {
                      setState(() {
                        _selectedTag = null;
                        _applyFilter(notify: false);
                      });
                    },
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem(
                  l10n.log_total,
                  _allLogs.length,
                  Colors.blue,
                  selected: !_problemsOnly && _minLevel == null,
                  onTap: () {
                    setState(() {
                      _problemsOnly = false;
                      _minLevel = null;
                      _applyFilter(notify: false);
                    });
                  },
                ),
                _buildStatItem(
                  l10n.log_levelError,
                  errorCount,
                  Colors.red,
                  selected: _minLevel == LogLevel.error ||
                      (_problemsOnly && warningCount == 0),
                  onTap: () {
                    setState(() {
                      _problemsOnly = false;
                      _minLevel = LogLevel.error;
                      _applyFilter(notify: false);
                    });
                  },
                ),
                _buildStatItem(
                  l10n.log_levelWarning,
                  warningCount,
                  Colors.orange,
                  selected: _minLevel == LogLevel.warning,
                  onTap: () {
                    setState(() {
                      _problemsOnly = true;
                      _minLevel = null;
                      _applyFilter(notify: false);
                    });
                  },
                ),
                _buildStatItem(
                  l10n.log_visible,
                  _logs.length,
                  Colors.teal,
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _logs.isEmpty
                    ? _buildEmpty(l10n)
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

  Widget _buildEmpty(AppLocalizations l10n) {
    final hasSource = _allLogs.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
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
              hasSource ? l10n.log_noMatch : l10n.log_noLogs,
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              hasSource ? l10n.log_noMatchHint : l10n.log_emptyHint,
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

  Widget _buildLogItem(LogEntry log) {
    final scheme = Theme.of(context).colorScheme;
    final tagLabel = log.tag != null ? ' [${log.tag}]' : '';
    final accent = _levelColor(log.level);
    final preview = log.error != null && log.error!.isNotEmpty
        ? log.error!
        : log.message;

    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          log.message,
          style: const TextStyle(fontSize: 14),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        if (log.level == LogLevel.error &&
            log.error != null &&
            log.error!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: scheme.error,
                fontFamily: 'monospace',
              ),
            ),
          ),
      ],
    );

    final subtitle = Text(
      '${log.timeString} • ${log.levelString}$tagLabel',
      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
    );

    final tile = log.hasDetails
        ? ExpansionTile(
            leading: _getLogIcon(log.level),
            title: title,
            subtitle: subtitle,
            children: [
              _buildDetailBlock(log),
            ],
          )
        : ListTile(
            leading: _getLogIcon(log.level),
            title: title,
            subtitle: subtitle,
            trailing: IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: AppLocalizations.of(context).common_copy,
              onPressed: () => _copyLog(log),
            ),
            onLongPress: () => _copyLog(log),
          );

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: accent, width: 3),
          ),
        ),
        child: tile,
      ),
    );
  }

  Widget _buildDetailBlock(LogEntry log) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _copyLog(log),
              icon: const Icon(Icons.copy, size: 16),
              label: Text(AppLocalizations.of(context).common_copy),
            ),
          ),
          SelectableText(
            log.message,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          if (log.error != null && log.error!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(
                'Error: ${log.error}',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
          ],
          if (log.stackTrace != null && log.stackTrace!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(
                log.stackTrace!,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _levelColor(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return Colors.grey;
      case LogLevel.info:
        return Colors.blue;
      case LogLevel.warning:
        return Colors.orange;
      case LogLevel.error:
        return Colors.red;
    }
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
