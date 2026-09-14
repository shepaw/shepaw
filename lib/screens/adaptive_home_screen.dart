import 'package:flutter/material.dart';
import '../utils/layout_utils.dart';
import '../services/logger_service.dart';
import '../services/update_notification_service.dart';
import '../services/update_service.dart';
import 'desktop_home_screen.dart';
import 'home_screen.dart';

/// Routes to either [DesktopHomeScreen] (split-panel) or [HomeScreen] (mobile)
/// based on platform and window width. Rebuilds automatically on window resize
/// via [MediaQuery].
///
/// Also performs a background update check on first load.
class AdaptiveHomeScreen extends StatefulWidget {
  const AdaptiveHomeScreen({super.key});

  @override
  State<AdaptiveHomeScreen> createState() => _AdaptiveHomeScreenState();
}

class _AdaptiveHomeScreenState extends State<AdaptiveHomeScreen> {
  final _logger = LoggerService();

  @override
  void initState() {
    super.initState();
    _logger.info('AdaptiveHomeScreen initState', tag: 'HomeBoot');
    // 延迟到第一帧渲染完成后再检查，避免阻塞 UI 初始化
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _logger.info('postFrame: start background tasks', tag: 'HomeBoot');
      try {
        await UpdateService().loadBadgeState();
        _logger.info('postFrame: loadBadgeState done', tag: 'HomeBoot');
        // 1. 先检查是否有待安装包（上次下载完成但用户选择了「稍后」）
        if (mounted) {
          await UpdateNotificationService().checkAndInstallPending(context);
          _logger.info('postFrame: checkAndInstallPending done', tag: 'HomeBoot');
        }
        // 2. 再检查是否有新版本
        if (mounted) {
          await _checkForUpdates();
        }
        _logger.info('postFrame: all background tasks done', tag: 'HomeBoot');
      } catch (e, stack) {
        _logger.error(
          'postFrame background tasks failed',
          tag: 'HomeBoot',
          error: e,
          stackTrace: stack,
        );
      }
    });
  }

  Future<void> _checkForUpdates() async {
    _logger.info('checkForUpdate starting', tag: 'HomeBoot');
    final result = await UpdateService().checkForUpdate();
    _logger.info(
      'checkForUpdate done: hasUpdate=${result.hasUpdate}, error=${result.error}',
      tag: 'HomeBoot',
    );
    if (!mounted) return;
    if (result.hasUpdate && result.updateInfo != null) {
      _logger.info(
        'notifyUpdateAvailable for ${result.updateInfo!.version}',
        tag: 'HomeBoot',
      );
      await UpdateNotificationService().notifyUpdateAvailable(
        result.updateInfo!,
        context,
      );
      _logger.info('notifyUpdateAvailable done', tag: 'HomeBoot');
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop = LayoutUtils.isDesktopLayout(context);
    _logger.info('AdaptiveHomeScreen build: desktop=$desktop', tag: 'HomeBoot');
    return desktop ? const DesktopHomeScreen() : const HomeScreen();
  }
}
