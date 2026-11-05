import 'dart:async';

import 'app_lock_service.dart';

/// 把「该不该弹锁屏」从 `_MyAppState` 里拿出来，方便测。
///
/// 规则很简单：锁着、有登录态、栈顶不是门页，就压一张锁屏，且同一时刻只压一张。
/// 不按路由名自动放行 —— 「离线进入」之类的路径不经过密码就能进主页，
/// 只要 [AppLockService.locked] 还是真，进主页就必须过指纹。
class AppLockCoordinator {
  AppLockCoordinator({
    required this.lock,
    required this.hasSession,
    required this.onGate,
    required this.pushLockScreen,
  });

  final AppLockService lock;
  final Future<bool> Function() hasSession;

  /// 根导航栈顶是不是门页（登录 / 解锁 / 锁屏本身）。
  final bool Function() onGate;

  /// 压锁屏，返回时说明锁屏已经关掉。
  final Future<void> Function() pushLockScreen;

  bool _showing = false;

  /// 读登录态、加载开关。没有登录态的启动不上锁。
  Future<void> start() async {
    await lock.load(hasSession: await hasSession());
    await check();
  }

  /// 状态或路由变了就调一次。
  Future<void> check() async {
    if (_showing || !lock.locked || onGate()) return;
    _showing = true;
    try {
      if (!await hasSession() || !lock.locked || onGate()) return;
      await pushLockScreen();
    } finally {
      _showing = false;
    }
  }
}
