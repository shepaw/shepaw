import 'package:flutter/material.dart';

/// 登录 / 配对 / 启动这些门页。
///
/// 这些页面上既不能显示审核条，也不能让通知 / 深链直接推进聊天：手机冷启动
/// 时有效 token 和登录页可以同时存在，登录页才是用户这次会话的入口。
const loginGateRoutes = <String>{
  '/',
  '/setup',
  '/login',
  '/pouch',
  '/host-setup',
  '/welcome',
  '/host-install',
  '/create-password',
  '/setup-done',
  '/pouch-init',
  '/pouch-unlock',
  '/unlock',
  '/remote-connect',
  '/phone-login',
};

/// 具名门页之外（聊天、主页等）不算门页。无名路由默认按登录后处理。
bool isLoginGateRoute(String? routeName) {
  final name = routeName?.trim() ?? '';
  if (name.isEmpty) return false;
  return loginGateRoutes.contains(name);
}

/// 记录根 Navigator 当前是否停在门页上，供审核条和深链校验共用。
class RouteGateObserver extends NavigatorObserver {
  RouteGateObserver();

  static final RouteGateObserver instance = RouteGateObserver();

  /// 启动时先当作门页处理，等第一张路由压栈后再判定。
  static final ValueNotifier<bool> onGate = ValueNotifier<bool>(true);

  static void _update(Route<dynamic>? route) {
    if (route == null) {
      onGate.value = true;
      return;
    }
    // 弹窗 / 底部弹层沿用底下的页面：登录页上的弹窗不能把审核条带出来。
    if (route is PopupRoute) return;
    onGate.value = isLoginGateRoute(route.settings.name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _update(newRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(previousRoute);
}
