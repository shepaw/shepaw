import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/desktop_window_auto_size.dart';

/// 验证窗口宽度 clamp 语义（纯计算，不依赖 window_manager 插件）：
/// 面板展开 / 收起 / 拖拽分割线 / 启动恢复四类场景共用同一个增减 + 下限
/// 规则，聊天区宽度永远不会低于无面板时的最小窗口宽度。
void main() {
  group('DesktopWindowAutoSize.adjustedWidth', () {
    // 场景均按「面板宽 361（面板 360 + 分割线 1），基础最小窗口宽 800」
    // 构造：面板展开期间最小宽 = 800 + 361 = 1161。

    test('展开面板：窗口在原宽度上 + 面板宽，聊天区保持不变', () {
      // 当前 1000 的窗口，展开后应为 1000 + 361 = 1361。
      expect(DesktopWindowAutoSize.adjustedWidth(1000, 361, 1161), 1361);
      // 窗口很窄时也不低于「基础最小 + 面板宽」。
      expect(DesktopWindowAutoSize.adjustedWidth(800, 361, 1161), 1161);
    });

    test('收起面板：窗口 - 面板宽，但不低于基础最小宽 800', () {
      expect(DesktopWindowAutoSize.adjustedWidth(1361, -361, 800), 1000);
      // 原本就贴着下限时收起，钳到 800。
      expect(DesktopWindowAutoSize.adjustedWidth(1161, -361, 800), 800);
    });

    test('拖拽加宽面板：窗口随动但不低于 800 + 新面板宽', () {
      // 面板 360 → 480（delta = -120），新下限 = 800 + 481 = 1281，
      // 窗口 1161 应钳到 1281，聊天区保持 800。
      expect(DesktopWindowAutoSize.adjustedWidth(1161, -120, 1281), 1281);
      // 面板变窄（delta > 0）时窗口加宽、聊天区随之变宽。
      expect(DesktopWindowAutoSize.adjustedWidth(1161, 120, 1041), 1281);
    });

    test('启动恢复：窗口不足 800 + 面板宽才拉宽，否则保持原宽', () {
      // 上次结束在 800 且面板已固定：补足到 1161。
      expect(DesktopWindowAutoSize.adjustedWidth(800, 0, 1161), 1161);
      // 上次结束在 1161 及以上：保持不动，不重复加宽。
      expect(DesktopWindowAutoSize.adjustedWidth(1161, 0, 1161), 1161);
      expect(DesktopWindowAutoSize.adjustedWidth(1500, 0, 1161), 1500);
    });
  });
}
