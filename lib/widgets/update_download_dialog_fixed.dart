import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/update_model.dart';
import '../services/file_download_service.dart';
import '../services/logger_service.dart';

/// 下载进度对话框
/// 显示文件下载进度、速度和剩余时间
class UpdateDownloadDialog extends StatefulWidget {
  final String downloadUrl;
  final String fileName;
  final int? totalSize;

  const UpdateDownloadDialog({
    super.key,
    required this.downloadUrl,
    required this.fileName,
    this.totalSize,
  });

  @override
  State<UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<UpdateDownloadDialog> {
  late FileDownloadService _downloadService;
  DownloadProgress? _progress;
  UpdateDownloadState _state = UpdateDownloadState.downloading;
  String? _error;
  DateTime? _startTime;
  int? _lastBytesDownloaded;
  late LoggerService _logger;

  @override
  void initState() {
    super.initState();
    _logger = LoggerService();
    _downloadService = FileDownloadService();
    _startTime = DateTime.now();
    _logger.info(
      'UpdateDownloadDialog.initState() - starting download for: ${widget.downloadUrl}',
      tag: 'UpdateDownloadDialog',
    );
    _startDownload();
  }

  Future<void> _startDownload() async {
    try {
      _logger.info(
        'Starting download: ${widget.downloadUrl}',
        tag: 'UpdateDownloadDialog',
      );

      await _downloadService.downloadAndSave(
        widget.downloadUrl,
        fileName: widget.fileName,
        expectedSize: widget.totalSize,
        onProgress: _handleProgress,
      );

      _logger.info('Download completed successfully', tag: 'UpdateDownloadDialog');

      if (!mounted) return;
      setState(() => _state = UpdateDownloadState.completed);

      // 下载完成 1 秒后自动关闭
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e, stack) {
      _logger.error(
        'Download failed with exception',
        tag: 'UpdateDownloadDialog',
        error: e,
        stackTrace: stack,
      );

      if (!mounted) return;
      setState(() {
        _state = UpdateDownloadState.failed;
        _error = e.toString();
      });
    }
  }

  void _handleProgress(int downloaded, int? total) {
    _lastBytesDownloaded = downloaded;

    if (!mounted) return;
    setState(() {
      _progress = DownloadProgress(
        downloadedBytes: downloaded,
        totalBytes: total,
      );
    });
  }

  String _formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    } else if (duration.inMinutes > 0) {
      return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
    } else {
      return '${duration.inSeconds}s';
    }
  }

  String _calculateTimeRemaining() {
    if (_progress == null ||
        _progress!.totalBytes == null ||
        _startTime == null ||
        _progress!.percentage == 0) {
      return '--';
    }

    final elapsedTime = DateTime.now().difference(_startTime!);
    final totalEstimate = elapsedTime.inMilliseconds / (_progress!.percentage / 100);
    final remainingMillis = (totalEstimate - elapsedTime.inMilliseconds).toInt();

    if (remainingMillis <= 0) return '0s';
    return _formatDuration(Duration(milliseconds: remainingMillis));
  }

  String _calculateSpeed() {
    if (_startTime == null || _lastBytesDownloaded == null) return '0 KB';

    final elapsedSeconds = DateTime.now().difference(_startTime!).inSeconds;
    if (elapsedSeconds == 0) return '0 KB';

    final speedBytesPerSec = _lastBytesDownloaded! / elapsedSeconds;
    return DownloadProgress.formatBytes(speedBytesPerSec.toInt());
  }

  Future<void> _retry() async {
    setState(() {
      _state = UpdateDownloadState.downloading;
      _error = null;
      _progress = null;
      _startTime = DateTime.now();
    });
    await _startDownload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          if (_state == UpdateDownloadState.downloading)
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colorScheme.primary,
              ),
            )
          else if (_state == UpdateDownloadState.completed)
            Icon(Icons.check_circle, color: Colors.green[600], size: 24)
          else if (_state == UpdateDownloadState.failed)
            Icon(Icons.error_outline, color: colorScheme.error, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _state == UpdateDownloadState.downloading
                  ? l10n.update_downloading
                  : _state == UpdateDownloadState.completed
                      ? l10n.update_downloadCompleted
                      : l10n.update_downloadFailed,
              style: theme.textTheme.titleMedium,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 文件名
            Text(
              widget.fileName,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),

            // 下载进度条
            if (_state == UpdateDownloadState.downloading && _progress != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progress!.percentage / 100,
                  minHeight: 6,
                  backgroundColor: Colors.grey[300],
                  valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                ),
              ),
              const SizedBox(height: 12),

              // 进度信息
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${_progress!.percentage}%',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    l10n.update_downloadProgress(
                      DownloadProgress.formatBytes(_progress!.downloadedBytes),
                      _progress!.totalBytes != null
                          ? DownloadProgress.formatBytes(_progress!.totalBytes!)
                          : '?',
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // 速度和剩余时间
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.speed, size: 14, color: Colors.grey[500]),
                      const SizedBox(width: 4),
                      Text(
                        l10n.update_downloadSpeed(_calculateSpeed()),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Icon(Icons.schedule, size: 14, color: Colors.grey[500]),
                      const SizedBox(width: 4),
                      Text(
                        l10n.update_downloadTimeRemaining(_calculateTimeRemaining()),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ]
            // 完成状态
            else if (_state == UpdateDownloadState.completed) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green[600], size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${widget.fileName} 下载完成',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.green[700],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ]
            // 失败状态
            else if (_state == UpdateDownloadState.failed) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer.withAlpha(77),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.update_downloadFailed,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.error,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        _error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.error,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_state == UpdateDownloadState.failed)
          TextButton(
            onPressed: _retry,
            child: Text(l10n.update_retryDownload),
          ),
        if (_state != UpdateDownloadState.downloading)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
      ],
    );
  }
}
