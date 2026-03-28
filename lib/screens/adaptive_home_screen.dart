import 'package:flutter/material.dart';
import '../utils/layout_utils.dart';
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
  @override
  void initState() {
    super.initState();
    // 延迟到第一帧渲染完成后再检查，避免阻塞 UI 初始化
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 1. 先检查是否有待安装包（上次下载完成但用户选择了「稍后」）
      if (mounted) {
        await UpdateNotificationService().checkAndInstallPending(context);
      }
      // 2. 再检查是否有新版本
      if (mounted) {
        _checkForUpdates();
      }
    });
  }

  Future<void> _checkForUpdates() async {
    final result = await UpdateService().checkForUpdate();
    if (!mounted) return;
    if (result.hasUpdate && result.updateInfo != null) {
      await UpdateNotificationService().notifyUpdateAvailable(
        result.updateInfo!,
        context,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutUtils.isDesktopLayout(context)
        ? const DesktopHomeScreen()
        : const HomeScreen();
  }
}
