import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:math' show min;
import '../l10n/app_localizations.dart';
import '../models/update_model.dart';
import '../services/update_service.dart';
import '../widgets/update_settings_badge.dart';
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

  /// 桌面平台使用应用内下载进度对话框；移动端打开外部链接
  Future<void> _handleDownload(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final isDesktop = defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;

    // Add comprehensive logging for debugging
    final urlPreview = updateInfo.downloadUrl.isEmpty
        ? "(empty)"
        : updateInfo.downloadUrl.substring(0, min(60, updateInfo.downloadUrl.length));

    final logger = LoggerService();
    logger.info(
      'Download handler called - isDesktop=$isDesktop, '
      'downloadUrl="$urlPreview", '
      'platform=$defaultTargetPlatform, '
      'mandatory=${updateInfo.isMandatory}',
      tag: 'UpdateDialog',
    );

    if (updateInfo.downloadUrl.isEmpty) {
      logger.warning(
        'downloadUrl is empty! updateInfo.version=${updateInfo.version}, '
        'isMandatory=${updateInfo.isMandatory}. '
        'Check that the appcheck API response contains a "downloadUrl" field.',
        tag: 'UpdateDialog',
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.update_emptyDownloadUrl)),
        );
      }
      return;
    }

    if (isDesktop) {
      final fileName = _extractFileName(updateInfo.downloadUrl);
      logger.info('Showing UpdateDownloadDialog for $fileName', tag: 'UpdateDialog');

      // Show download dialog first (keep update dialog alive so context remains valid)
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => UpdateDownloadDialog(
          downloadUrl: updateInfo.downloadUrl,
          fileName: fileName,
          totalSize: updateInfo.fileSize,
        ),
      );
      // Close the update dialog after download dialog is done
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    } else {
      logger.info('Using external URL launcher', tag: 'UpdateDialog');
      // Mobile / Web: open external browser / App Store
      final url = Uri.tryParse(updateInfo.downloadUrl);
      if (url != null) {
        try {
          await launchUrl(url, mode: LaunchMode.externalApplication);
        } catch (e) {
          logger.warning('launchUrl failed: $e', tag: 'UpdateDialog');
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  l10n.update_cannotOpenUrl(updateInfo.downloadUrl),
                ),
              ),
            );
          }
        }
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
  String? _checkUrl;

  @override
  void initState() {
    super.initState();
    _loadCheckUrl();
    UpdateService().addListener(_loadCheckUrl);
  }

  @override
  void dispose() {
    UpdateService().removeListener(_loadCheckUrl);
    super.dispose();
  }

  Future<void> _loadCheckUrl() async {
    final url = await UpdateService().getCheckUpdateUrl();
    if (mounted) setState(() => _checkUrl = url);
  }

  Future<void> _editCheckUrl() async {
    if (_state == _CheckState.checking) return;
    final l10n = AppLocalizations.of(context);
    final service = UpdateService();
    final baseUrl = await service.getCheckUpdateBaseUrl();
    final controller = TextEditingController(text: baseUrl);
    final hasCustom = await service.hasCustomCheckUpdateBaseUrl();
    if (!mounted) return;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        String? errorText;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(l10n.update_checkDomainTitle),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: controller,
                      decoration: InputDecoration(
                        hintText: l10n.update_checkDomainHint,
                        errorText: errorText,
                        border: const OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      autofocus: true,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.update_checkUrlFixedPath(UpdateService.checkEndpoint),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                    if (hasCustom) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () {
                            controller.text = UpdateService.defaultBaseUrl;
                            setDialogState(() => errorText = null);
                          },
                          child: Text(l10n.update_checkUrlReset),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(l10n.common_cancel),
                ),
                FilledButton(
                  onPressed: () {
                    final validated =
                        service.validateCheckUpdateBaseUrl(controller.text);
                    if (validated == null) {
                      setDialogState(
                        () => errorText = l10n.update_checkDomainInvalid,
                      );
                      return;
                    }
                    Navigator.of(ctx).pop(true);
                  },
                  child: Text(l10n.common_save),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved == true) {
      final validated = service.validateCheckUpdateBaseUrl(controller.text);
      if (validated != null) {
        final isDefault = validated == UpdateService.defaultBaseUrl;
        await service.setCustomCheckUpdateBaseUrl(isDefault ? null : validated);
      }
    }
    controller.dispose();
  }

  Future<void> _check() async {
    if (_state == _CheckState.checking) return;

    await UpdateService().dismissCheckUpdateNewBadge();

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
        subtitle = _checkUrl != null
            ? l10n.update_checkingFromUrl(_checkUrl!)
            : l10n.update_checking;
        break;
      case _CheckState.upToDate:
        trailing = Icon(Icons.check_circle, color: Colors.green[600], size: 22);
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
        trailing = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
              tooltip: l10n.update_editCheckDomain,
              visualDensity: VisualDensity.compact,
              onPressed: _editCheckUrl,
            ),
            const Icon(Icons.chevron_right),
          ],
        );
        subtitle = _checkUrl != null
            ? l10n.update_checkUrlSub(_checkUrl!)
            : l10n.settings_checkForUpdatesSub;
        break;
    }

    return ListenableBuilder(
      listenable: UpdateService(),
      builder: (context, _) {
        final showNewBadge = UpdateService().showCheckUpdateNewBadge;

        return ListTile(
          leading: const Icon(Icons.system_update_alt),
          title: Row(
            children: [
              Text(l10n.settings_checkForUpdates),
              if (showNewBadge) ...[
                const SizedBox(width: 8),
                UpdateNewBadge(label: l10n.settings_checkForUpdatesNew),
              ],
            ],
          ),
          subtitle: Text(
            subtitle ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: trailing,
          onTap: _state == _CheckState.checking ? null : _check,
        );
      },
    );
  }
}
