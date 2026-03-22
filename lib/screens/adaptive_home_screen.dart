import 'package:flutter/material.dart';
import '../utils/layout_utils.dart';
import 'desktop_home_screen.dart';
import 'home_screen.dart';

/// Routes to either [DesktopHomeScreen] (split-panel) or [HomeScreen] (mobile)
/// based on platform and window width. Rebuilds automatically on window resize
/// via [MediaQuery].
class AdaptiveHomeScreen extends StatelessWidget {
  const AdaptiveHomeScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return LayoutUtils.isDesktopLayout(context)
        ? const DesktopHomeScreen()
        : const HomeScreen();
  }
}
