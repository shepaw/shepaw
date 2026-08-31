import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:window_manager/window_manager.dart';

/// 桌面主窗口「随停靠面板开合自适应宽度」：固定会话面板时窗口拉宽以
/// 容纳面板，取消固定时缩回，免去手动拉伸窗口。
///
/// 只改宽度、不动高度与位置；无状态——以调用时刻的实际宽度为基准增减，
/// 用户手动调整过窗口也能得到合理结果。
///
/// 宽度下限与 macOS 原生层声明的最小窗口宽度一致
/// （MainFlutterWindow.minSize 800x400）：面板展开期间最小窗口宽度动态抬到
/// 800 + 面板宽，用户手动把窗口拉小也不会挤压聊天区；取消固定后复位。
///
/// 仅主窗口使用（main.dart 启动时初始化）；子窗口由 SubWindowApp 自管。
class DesktopWindowAutoSize {
  DesktopWindowAutoSize._();

  /// 无面板时的最小窗口宽度（与 macOS 原生 minSize 一致）。
  static const double _baseMinWindowWidth = 800;
  static const double _baseMinWindowHeight = 400;

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

  /// 面板即将展开：窗口加宽 [panelWidth] 让聊天区保持原宽度，并把最小
  /// 窗口宽度抬到 800 + [panelWidth]，防止手动缩小窗口挤压聊天区。
  static Future<void> growForPanel(double panelWidth) async {
    if (!_enabled || panelWidth == 0) return;
    try {
      final minWidth = _panelMinWidth(panelWidth);
      await windowManager.setMinimumSize(Size(minWidth, _baseMinWindowHeight));
      await _resizeWidth(
        (size) => adjustedWidth(size.width, panelWidth, minWidth),
      );
    } catch (_) {
      // 插件不可用时忽略，面板仍以内嵌方式展示。
    }
  }

  /// 面板即将收起：窗口缩回 [panelWidth]，最低回到 800，并复位最小宽度。
  static Future<void> shrinkForPanel(double panelWidth) async {
    if (!_enabled || panelWidth == 0) return;
    try {
      await windowManager.setMinimumSize(
        const Size(_baseMinWindowWidth, _baseMinWindowHeight),
      );
      await _resizeWidth(
        (size) => adjustedWidth(
            size.width, -panelWidth, _baseMinWindowWidth),
      );
    } catch (_) {
      // 插件不可用时忽略，面板仍以内嵌方式展示。
    }
  }

  /// 面板宽度变化（拖拽分割线）时窗口随动，聊天区保持原宽度：窗口宽度
  /// 增减 [delta]（旧面板宽 - 新面板宽），最小宽度同步为 800 + [panelWidth]。
  static Future<void> adjustWidthForPanel(double delta, double panelWidth) async {
    if (!_enabled || delta == 0) return;
    try {
      final minWidth = _panelMinWidth(panelWidth);
      await windowManager.setMinimumSize(Size(minWidth, _baseMinWindowHeight));
      await _resizeWidth(
        (size) => adjustedWidth(size.width, delta, minWidth),
      );
    } catch (_) {
      // 插件不可用时忽略，面板仍以内嵌方式展示。
    }
  }

  /// 启动恢复：面板已固定时确保窗口宽度 >= 800 + [panelWidth]（不足才拉宽，
  /// 不重复加宽），并把最小宽度同步抬高，避免启动即挤压聊天区。
  static Future<void> ensurePanelSpace(double panelWidth) async {
    if (!_enabled || panelWidth == 0) return;
    try {
      final minWidth = _panelMinWidth(panelWidth);
      await windowManager.setMinimumSize(Size(minWidth, _baseMinWindowHeight));
      await _resizeWidth(
        (size) => adjustedWidth(size.width, 0, minWidth),
      );
    } catch (_) {
      // 插件不可用时忽略，面板仍以内嵌方式展示。
    }
  }

  /// 面板展开期间窗口应保持的最小宽度：最小聊天区（[_baseMinWindowWidth]）
  /// + 面板宽。
  static double _panelMinWidth(double panelWidth) =>
      _baseMinWindowWidth + panelWidth;

  /// 仅在宽度变化时调用 setSize（相等时跳过，避免无谓的平台调用）。
  static Future<void> _resizeWidth(double Function(Size) nextWidth) async {
    final size = await windowManager.getSize();
    final width = nextWidth(size);
    if (width != size.width) {
      await windowManager.setSize(Size(width, size.height));
    }
  }

  /// 窗口宽度随 [delta] 增减后的结果，且不低于 [minWidth]。
  /// 纯计算，供测试直接验证 clamp 语义。
  @visibleForTesting
  static double adjustedWidth(double current, double delta, double minWidth) =>
      math.max(minWidth, current + delta);

  static bool get _enabled =>
      _initialized &&
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
}
