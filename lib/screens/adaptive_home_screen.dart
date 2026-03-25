import 'package:flutter/material.dart';
import '../utils/layout_utils.dart';
import '../services/update_service.dart';
import '../widgets/update_dialog.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForUpdates();
    });
  }

  Future<void> _checkForUpdates() async {
    final result = await UpdateService().checkForUpdate();
    if (!mounted) return;
    if (result.hasUpdate && result.updateInfo != null) {
      final currentVersion = await UpdateService().getCurrentVersion();
      if (!mounted) return;
      await UpdateDialog.show(
        context,
        updateInfo: result.updateInfo!,
        currentVersion: currentVersion.versionString,
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
