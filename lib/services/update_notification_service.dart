import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../models/update_model.dart';
import 'logger_service.dart';
import 'notification_service.dart';

/// 负责更新通知流程的完整编排：
///
/// 1. 检测到新版本 → 发系统通知
/// 2. 用户点击通知 → 弹对话框（同意/拒绝/稍后）
/// 3. 同意 → 后台下载，完成后再发通知
/// 4. 用户点击"立即安装" → 调用平台安装程序
/// 5. 用户点击"稍后"或关闭 → 写入 pending，下次启动时自动提示
///
/// ## SharedPreferences 键
/// - [_prefDeclinedVersion]  : 用户永久拒绝的版本号
/// - [_prefPendingPath]      : 已下载待安装的文件绝对路径
/// - [_prefPendingVersion]   : 待安装的版本号（用于提示文本）
class UpdateNotificationService {
  static final UpdateNotificationService _instance =
      UpdateNotificationService._internal();
  factory UpdateNotificationService() => _instance;
  UpdateNotificationService._internal();

  static const int _notifIdAvailable = 9001;
  static const int _notifIdReady = 9002;

  static const String _prefDeclinedVersion = 'update_declined_version';
  static const String _prefPendingPath = 'update_pending_install_path';
  static const String _prefPendingVersion = 'update_pending_install_version';

  final _logger = LoggerService();

  // BuildContext 通过弱引用方式保存，用于在通知点击时弹出对话框
  // 使用 GlobalKey<NavigatorState> 比保存 BuildContext 更安全
  GlobalKey<NavigatorState>? _navigatorKey;

  // 当前等待下载的更新信息，用于通知点击时恢复上下文
  UpdateInfo? _pendingUpdateInfo;

  // ==================== 初始化 ====================

  /// 初始化服务，注册通知点击回调。
  /// 必须在 [NotificationService.init()] 之后调用。
  void init({GlobalKey<NavigatorState>? navigatorKey}) {
    _navigatorKey = navigatorKey;
    NotificationService().setOnNotificationTap(_handleNotificationTap);
    _logger.info('UpdateNotificationService initialized', tag: 'UpdateNotification');
  }

  // ==================== 公开 API ====================

  /// 当检测到新版本时调用。
  ///
  /// 若当前版本已被用户永久拒绝，则静默忽略。
  /// 否则发送系统通知，用户点击后弹出更新对话框。
  Future<void> notifyUpdateAvailable(
    UpdateInfo info,
    BuildContext context,
  ) async {
    // l10n 必须在第一个 await 前提取，避免跨 async 使用 BuildContext
    final title = AppLocalizations.of(context)
        .update_notification_availableTitle(info.version);
    final body =
        AppLocalizations.of(context).update_notification_availableBody;

    // 检查是否已被永久拒绝
    final declined = await _getDeclinedVersion();
    if (declined == info.version && !info.isMandatory) {
      _logger.info(
        'Version ${info.version} was permanently declined, skipping notification',
        tag: 'UpdateNotification',
      );
      return;
    }

    _pendingUpdateInfo = info;

    await NotificationService().showNotification(
      id: _notifIdAvailable,
      title: title,
      body: body,
      payload: 'update_available',
    );

    _logger.info(
      'Sent update-available notification for ${info.version}',
      tag: 'UpdateNotification',
    );
  }

  /// 启动时检查是否有待安装的更新包。
  /// 若有，弹出对话框让用户选择立即安装或稍后。
  Future<void> checkAndInstallPending(BuildContext context) async {
    final path = await _getPendingPath();
    final version = await _getPendingVersion();
    if (path == null || version == null) return;

    // 确认文件仍然存在
    if (!File(path).existsSync()) {
      await _clearPending();
      return;
    }

    _logger.info(
      'Found pending install: $version at $path',
      tag: 'UpdateNotification',
    );

    if (!context.mounted) return;
    await _showInstallDialog(context, filePath: path, version: version);
  }

  // ==================== 内部流程 ====================

  /// 处理通知点击，根据 payload 路由到对应逻辑。
  void _handleNotificationTap(String? payload) {
    if (payload == null) return;
    _logger.info('Notification tapped: $payload', tag: 'UpdateNotification');

    final ctx = _navigatorKey?.currentContext;
    if (ctx == null) return;

    if (payload == 'update_available' && _pendingUpdateInfo != null) {
      _showUpdateDialog(ctx, _pendingUpdateInfo!);
    } else if (payload == 'update_ready') {
      _resumePendingInstallFromNotification(ctx);
    }
  }

  /// 弹出更新信息对话框（同意/拒绝/稍后）。
  Future<void> _showUpdateDialog(BuildContext context, UpdateInfo info) async {
    if (!context.mounted) return;
    // l10n 提前提取，避免跨 async gap 后使用 context
    final result = await showDialog<_UpdateDialogResult>(
      context: context,
      barrierDismissible: !info.isMandatory,
      builder: (ctx) => _UpdatePromptDialog(info: info),
    );

    switch (result) {
      case _UpdateDialogResult.accept:
        if (!context.mounted) return;
        await _startDownload(info, context, AppLocalizations.of(context));
        break;
      case _UpdateDialogResult.decline:
        await _declineVersion(info.version);
        await NotificationService().cancelNotification(_notifIdAvailable);
        break;
      case _UpdateDialogResult.later:
      case null:
        // 稍后提醒，不做处理
        break;
    }
  }

  /// 后台下载更新包。
  Future<void> _startDownload(
    UpdateInfo info,
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    _logger.info(
      'Starting download for ${info.version}: ${info.downloadUrl}',
      tag: 'UpdateNotification',
    );

    try {
      final filePath = await _downloadToTemp(
        info.downloadUrl,
        info.version,
        onProgress: (received, total) {
          // 可在此更新进度通知（可选，暂不实现以保持简洁）
        },
      );

      // 写入 pending
      await _savePending(filePath, info.version);

      // 取消"有新版本"通知，发送"已就绪"通知
      await NotificationService().cancelNotification(_notifIdAvailable);
      if (context.mounted) {
        final readyL10n = AppLocalizations.of(context);
        await NotificationService().showNotification(
          id: _notifIdReady,
          title: readyL10n.update_notification_readyTitle,
          body: readyL10n.update_notification_readyBody(info.version),
          payload: 'update_ready',
        );
      }

      _logger.info(
        'Download complete: $filePath',
        tag: 'UpdateNotification',
      );
    } catch (e, stack) {
      _logger.error(
        'Download failed for ${info.version}',
        tag: 'UpdateNotification',
        error: e,
        stackTrace: stack,
      );
      // 下载失败时如果界面还在，弹一个简单提示
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${AppLocalizations.of(context).update_downloadFailed}: $e'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// 从通知点击路径恢复安装对话框（context 来自 NavigatorKey）。
  Future<void> _resumePendingInstallFromNotification(BuildContext context) async {
    final path = await _getPendingPath();
    final version = await _getPendingVersion();
    if (path == null || version == null) return;
    if (!File(path).existsSync()) {
      await _clearPending();
      return;
    }
    if (context.mounted) {
      await _showInstallDialog(context, filePath: path, version: version);
    }
  }

  /// 弹出安装确认对话框（立即安装/稍后）。
  Future<void> _showInstallDialog(
    BuildContext context, {
    required String filePath,
    required String version,
  }) async {
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.system_update, size: 24),
            const SizedBox(width: 8),
            Text(l10n.update_pendingInstallTitle),
          ],
        ),
        content: Text(l10n.update_pendingInstallBody(version)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.update_action_installLater),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.install_desktop, size: 18),
            label: Text(l10n.update_action_installNow),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _clearPending();
      await NotificationService().cancelNotification(_notifIdReady);
      await _installUpdate(filePath, version);
    }
    // confirmed == false → 保留 pending，下次启动再提示
  }

  /// 执行平台安装逻辑。
  Future<void> _installUpdate(String filePath, String version) async {
    _logger.info(
      'Installing update $version from $filePath',
      tag: 'UpdateNotification',
    );

    try {
      if (kIsWeb) {
        // Web 不支持本地安装
        return;
      }

      if (Platform.isAndroid) {
        // 通过系统包安装器安装 APK
        await OpenFile.open(filePath);
      } else if (Platform.isIOS) {
        // iOS 只能跳转到 App Store，不允许 sideload
        final updateInfo = _pendingUpdateInfo;
        final storeUrl = updateInfo?.downloadUrl ?? 'itms-apps://';
        final uri = Uri.parse(storeUrl);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      } else if (Platform.isMacOS) {
        // 打开 .dmg / .pkg / .zip
        await Process.run('open', [filePath]);
      } else if (Platform.isWindows) {
        // 启动安装程序后退出 app
        await Process.start(
          filePath,
          [],
          mode: ProcessStartMode.detached,
          runInShell: true,
        );
        exit(0);
      } else if (Platform.isLinux) {
        // 赋可执行权限再运行（.AppImage 或自定义安装脚本）
        await Process.run('chmod', ['+x', filePath]);
        await Process.start(
          filePath,
          [],
          mode: ProcessStartMode.detached,
        );
        exit(0);
      }
    } catch (e, stack) {
      _logger.error(
        'Failed to launch installer',
        tag: 'UpdateNotification',
        error: e,
        stackTrace: stack,
      );
    }
  }

  // ==================== 下载 ====================

  /// 将更新包下载到应用临时目录，返回文件绝对路径。
  Future<String> _downloadToTemp(
    String url,
    String version, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final fileName = _fileNameFromUrl(url, version);
    final file = File('${tempDir.path}/$fileName');

    // 如果已存在同名文件，直接复用（断点续传简化版）
    if (await file.exists()) {
      return file.path;
    }

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final total = response.contentLength;
      int received = 0;
      final sink = file.openWrite();

      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }

      return file.path;
    } finally {
      client.close();
    }
  }

  /// 从下载 URL 派生文件名，不可解析时使用版本号兜底。
  String _fileNameFromUrl(String url, String version) {
    try {
      final segments = Uri.parse(url).pathSegments;
      if (segments.isNotEmpty && segments.last.contains('.')) {
        return segments.last;
      }
    } catch (_) {}
    return 'shepaw_$version';
  }

  // ==================== SharedPreferences 辅助 ====================

  Future<void> _declineVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefDeclinedVersion, version);
    _logger.info('Version $version permanently declined', tag: 'UpdateNotification');
  }

  Future<String?> _getDeclinedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefDeclinedVersion);
  }

  Future<void> _savePending(String filePath, String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefPendingPath, filePath);
    await prefs.setString(_prefPendingVersion, version);
  }

  Future<String?> _getPendingPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefPendingPath);
  }

  Future<String?> _getPendingVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefPendingVersion);
  }

  Future<void> _clearPending() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefPendingPath);
    await prefs.remove(_prefPendingVersion);
  }
}

// ==================== 内部枚举与对话框 ====================

enum _UpdateDialogResult { accept, decline, later }

/// 更新提示对话框（同意下载 / 拒绝 / 稍后）
class _UpdatePromptDialog extends StatelessWidget {
  final UpdateInfo info;

  const _UpdatePromptDialog({required this.info});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isMandatory = info.isMandatory;

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
              isMandatory ? l10n.update_mandatoryTitle : l10n.update_available,
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
            Text(
              l10n.update_availableVersion(info.version),
              style: theme.textTheme.bodyLarge
                  ?.copyWith(fontWeight: FontWeight.w500),
            ),
            if (isMandatory) ...[
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer.withAlpha(77),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  l10n.update_mandatoryMessage(info.version),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: colorScheme.error),
                ),
              ),
            ],
            if (info.description.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                l10n.update_releaseNotes,
                style: theme.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 140),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withAlpha(102),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  child: Text(info.description,
                      style: theme.textTheme.bodySmall),
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
            onPressed: () =>
                Navigator.of(context).pop(_UpdateDialogResult.decline),
            child: Text(
              l10n.update_action_decline,
              style: TextStyle(color: colorScheme.error),
            ),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_UpdateDialogResult.later),
            child: Text(l10n.update_action_installLater),
          ),
        ],
        FilledButton.icon(
          onPressed: () =>
              Navigator.of(context).pop(_UpdateDialogResult.accept),
          icon: const Icon(Icons.download, size: 18),
          label: Text(l10n.update_action_accept),
        ),
      ],
    );
  }
}
