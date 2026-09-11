import 'dart:io' show Platform;

/// 当前是不是桌面操作系统（macOS / Windows / Linux）。
///
/// 与 `LayoutUtils.isDesktopLayout` 的区别：那个还看窗口宽度，用来决定
/// 「用抽屉还是用底部弹层」；这个只看 OS，用来回答「这台机器有没有摄像头 /
/// 跑不跑得动 `mobile_scanner`」。混用会让窄窗口的桌面端误判成手机。
bool get isDesktopPlatform =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;
