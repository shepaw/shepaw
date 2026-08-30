import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:window_manager/window_manager.dart';

/// 桌面主窗口「随停靠面板开合自适应宽度」：固定会话面板时窗口拉宽以
/// 容纳面板，取消固定时缩回，免去手动拉伸窗口。
///
/// 只改宽度、不动高度与位置；无状态——以调用时刻的实际宽度为基准增减，
/// 用户手动调整过窗口也能得到合理结果。宽度下限与 macOS 原生层声明的
/// 最小窗口宽度一致（MainFlutterWindow.minSize）。
///
/// 仅主窗口使用（main.dart 启动时初始化）；子窗口由 SubWindowApp 自管。
class DesktopWindowAutoSize {
  DesktopWindowAutoSize._();

  static const double _minWindowWidth = 800;

  static bool _initialized = false;

  /// 初始化 window_manager 插件。重复调用安全。
  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await windowManager.ensureInitialized();
    } catch (_) {
      // 平台实现不可用（如测试环境）时保持静默，后续调用全部短路。
    }
  }

  /// 面板即将展开：窗口加宽 [panelWidth]，让聊天区保持原宽度。
  static Future<void> growForPanel(double panelWidth) =>
      adjustWidth(panelWidth);

  /// 面板即将收起：窗口缩回 [panelWidth]，不低于最小窗口宽度。
  static Future<void> shrinkForPanel(double panelWidth) =>
      adjustWidth(-panelWidth);

  /// 窗口宽度增减 [delta]（面板宽度拖拽时跟随），只改宽度不动高度。
  static Future<void> adjustWidth(double delta) async {
    if (!_enabled || delta == 0) return;
    try {
      final size = await windowManager.getSize();
      // 收缩时不超过最小窗口宽度；增长不设上限。
      final width = math.max(_minWindowWidth, size.width + delta);
      if (width != size.width) {
        await windowManager.setSize(Size(width, size.height));
      }
    } catch (_) {
      // 插件不可用时忽略，面板仍以内嵌方式展示。
    }
  }

  static bool get _enabled =>
      _initialized &&
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
}
