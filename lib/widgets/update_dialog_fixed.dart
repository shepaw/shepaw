import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:math' show min;
import '../l10n/app_localizations.dart';
import '../models/update_model.dart';
import '../services/update_service.dart';
import '../services/logger_service.dart';
import 'update_download_dialog.dart';

/// 更新对话框
///
/// 当有新版本可用时弹出，提供下载/跳过/稍后选项
class UpdateDialog extends StatelessWidget {
  final UpdateInfo updateInfo;
  final String currentVersion;

  const UpdateDialog({
    super.key,
    required this.updateInfo,
    required this.currentVersion,
  });

  /// 显示更新对话框，如果用户选择跳过，将版本记录到偏好设置
  static Future<void> show(
    BuildContext context, {
    required UpdateInfo updateInfo,
    required String currentVersion,
  }) async {
    await showDialog(
      context: context,
      barrierDismissible: !updateInfo.isMandatory,
      builder: (_) => UpdateDialog(
        updateInfo: updateInfo,
        currentVersion: currentVersion,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isMandatory = updateInfo.isMandatory;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(
            isMandatory ? Icons.system_update : Icons.system_update_alt,
            color: isMandatory ? colorScheme.error : colorScheme.primary,
            size: 24,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isMandatory
                  ? l10n.update_mandatoryTitle
                  : l10n.update_available,
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
            // 版本信息
            Text(
              l10n.update_availableVersion(updateInfo.version),
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.update_currentVersion(currentVersion),
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
              ),
            ),

            if (isMandatory) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer.withAlpha(77),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  l10n.update_mandatoryMessage(updateInfo.version),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.error,
                  ),
                ),
              ),
            ],

            // 更新日志
            if (updateInfo.description.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                l10n.update_releaseNotes,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 160),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withAlpha(102),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    updateInfo.description,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        if (!isMandatory) ...[
          TextButton(
            onPressed: () async {
              await UpdateService().skipVersion(updateInfo.version);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: Text(l10n.update_skipVersion),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.update_remindLater),
          ),
        ],
        FilledButton.icon(
          onPressed: () => _handleDownload(context),
          icon: const Icon(Icons.download, size: 18),
          label: Text(l10n.update_downloadNow),
        ),
      ],
    );
  }

  /// 桌面平台使用应用内下载进度对话框；移动端/Web 打开外部链接
  Future<void> _handleDownload(BuildContext context) async {
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux);

    // Add comprehensive logging for debugging
    final urlPreview = updateInfo.downloadUrl.isEmpty
        ? "(empty)"
        : updateInfo.downloadUrl.substring(0, min(60, updateInfo.downloadUrl.length));

    final logger = LoggerService();
    logger.info(
      'Download handler called - isDesktop=$isDesktop, '
      'downloadUrl="$urlPreview", '
      'kIsWeb=$kIsWeb, '
      'platform=$defaultTargetPlatform, '
      'mandatory=${updateInfo.isMandatory}',
      tag: 'UpdateDialog',
    );

    if (isDesktop && updateInfo.downloadUrl.isNotEmpty) {
      // Close the update dialog first (unless mandatory)
      if (!updateInfo.isMandatory && context.mounted) {
        Navigator.of(context).pop();
      }
      if (!context.mounted) {
        logger.warning('Context unmounted after Navigator.pop()', tag: 'UpdateDialog');
        return;
      }
      final fileName = _extractFileName(updateInfo.downloadUrl);
      logger.info('Showing UpdateDownloadDialog for $fileName', tag: 'UpdateDialog');

      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => UpdateDownloadDialog(
          downloadUrl: updateInfo.downloadUrl,
          fileName: fileName,
          totalSize: updateInfo.fileSize,
        ),
      );
      // For mandatory updates, close the update dialog after download
      if (updateInfo.isMandatory && context.mounted) {
        Navigator.of(context).pop();
      }
    } else {
      logger.info('Using external URL launcher', tag: 'UpdateDialog');
      // Mobile / Web: open external browser / App Store
      final url = Uri.tryParse(updateInfo.downloadUrl);
      if (url != null && await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
      if (context.mounted && !updateInfo.isMandatory) {
        Navigator.of(context).pop();
      }
    }
  }

  /// 从 URL 提取文件名，无法解析时返回默认名称
  String _extractFileName(String url) {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;
      if (segments.isNotEmpty && segments.last.contains('.')) {
        return segments.last;
      }
    } catch (_) {}
    return 'shepaw_update${updateInfo.version}';
  }
}

/// 检查更新状态枚举
enum _CheckState { idle, checking, upToDate, updateAvailable, failed }

/// "检查更新" ListTile 组件
///
/// 可以直接嵌入到设置页面中，包含完整的检查逻辑和状态显示
class CheckForUpdatesListTile extends StatefulWidget {
  const CheckForUpdatesListTile({super.key});

  @override
  State<CheckForUpdatesListTile> createState() =>
      _CheckForUpdatesListTileState();
}

class _CheckForUpdatesListTileState extends State<CheckForUpdatesListTile> {
  _CheckState _state = _CheckState.idle;
  String? _latestVersion;

  Future<void> _check() async {
    if (_state == _CheckState.checking) return;

    setState(() {
      _state = _CheckState.checking;
      _latestVersion = null;
    });

    // 强制检查（忽略冷却时间）
    await UpdateService().clearSkippedVersion();
    final result = await UpdateService().checkForUpdate(force: true);

    if (!mounted) return;

    if (result.error != null && !result.hasUpdate) {
      setState(() => _state = _CheckState.failed);
      return;
    }

    if (result.hasUpdate && result.updateInfo != null) {
      setState(() {
        _state = _CheckState.updateAvailable;
        _latestVersion = result.updateInfo!.version;
      });
      final currentVersion = await UpdateService().getCurrentVersion();
      if (mounted) {
        await UpdateDialog.show(
          context,
          updateInfo: result.updateInfo!,
          currentVersion: currentVersion.versionString,
        );
        if (mounted) setState(() => _state = _CheckState.idle);
      }
    } else {
      setState(() => _state = _CheckState.upToDate);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    Widget trailing;
    String? subtitle;

    switch (_state) {
      case _CheckState.checking:
        trailing = SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colorScheme.primary,
          ),
        );
        subtitle = l10n.update_checking;
        break;
      case _CheckState.upToDate:
        trailing = Icon(Icons.check_circle, color: Colors.green[600], size: 22);
        // 将在 FutureBuilder 中显示当前版本
        subtitle = l10n.settings_checkForUpdatesSub;
        break;
      case _CheckState.updateAvailable:
        trailing = Icon(Icons.new_releases, color: colorScheme.primary, size: 22);
        subtitle = _latestVersion != null
            ? l10n.update_availableVersion(_latestVersion!)
            : l10n.update_available;
        break;
      case _CheckState.failed:
        trailing = Icon(Icons.error_outline, color: colorScheme.error, size: 22);
        subtitle = l10n.update_checkFailed;
        break;
      case _CheckState.idle:
        trailing = const Icon(Icons.chevron_right);
        subtitle = l10n.settings_checkForUpdatesSub;
        break;
    }

    return ListTile(
      leading: const Icon(Icons.system_update_alt),
      title: Text(l10n.settings_checkForUpdates),
      subtitle: Text(subtitle),
      trailing: trailing,
      onTap: _state == _CheckState.checking ? null : _check,
    );
  }
}
