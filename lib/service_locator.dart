import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';

import 'services/local_database_service.dart';
import 'services/chat_service.dart';
import 'services/acp_server_service.dart';
import 'services/permission_service.dart';
import 'services/token_service.dart';
import 'services/remote_agent_service.dart';

/// 全局服务定位器（依赖注入容器）。
///
/// 作为应用的「组合根」（composition root），统一收口原先散落的全局可变变量
/// （`globalACPServer` / `globalPermissionService` / `navigatorKey`）以及核心
/// 单例服务的获取入口。新增需要全局共享的服务时，应在此注册，而不是再引入
/// 新的顶层全局变量或到处 `XxxService()`。
final GetIt getIt = GetIt.instance;

/// 注册应用启动期就能确定的核心对象与单例服务。
///
/// 必须在 [AppBootstrap.initialize] 之前调用（且仅需调用一次）；重复调用是安全的。
void setupServiceLocator() {
  if (getIt.isRegistered<GlobalKey<NavigatorState>>()) return;

  // 全局 Navigator Key（用于在任意位置弹出对话框 / 导航）
  getIt.registerSingleton<GlobalKey<NavigatorState>>(
    GlobalKey<NavigatorState>(),
  );

  // 核心单例服务：这些类本身即为构造单例，这里统一为 DI 获取入口，
  // 使后续代码可用 `getIt<T>()` 取用，而非直接构造。
  getIt.registerLazySingleton<LocalDatabaseService>(() => LocalDatabaseService());
  getIt.registerLazySingleton<ChatService>(() => ChatService());

  // Agent / Token 服务为无状态服务（仅持有 db 依赖），注册为共享单例，
  // 替代各处 `TokenService(db)` + `RemoteAgentService(db, tokenService)` 的重复构造。
  getIt.registerLazySingleton<TokenService>(
    () => TokenService(getIt<LocalDatabaseService>()),
  );
  getIt.registerLazySingleton<RemoteAgentService>(
    () => RemoteAgentService(getIt<LocalDatabaseService>(), getIt<TokenService>()),
  );
}

/// 在 ACP / 权限服务初始化完成后登记其实例。
///
/// 入参可能为 `null`（对应初始化失败），此时不注册，[acpServerOrNull] /
/// [permissionServiceOrNull] 将返回 `null`，调用方据此优雅降级。
void registerBootstrapServices({
  ACPServerService? acpServer,
  PermissionService? permissionService,
}) {
  if (acpServer != null && !getIt.isRegistered<ACPServerService>()) {
    getIt.registerSingleton<ACPServerService>(acpServer);
  }
  if (permissionService != null && !getIt.isRegistered<PermissionService>()) {
    getIt.registerSingleton<PermissionService>(permissionService);
  }
}

// ── 便捷访问器 ──────────────────────────────────────────────────────────

/// 全局 Navigator Key。
GlobalKey<NavigatorState> get navigatorKey =>
    getIt<GlobalKey<NavigatorState>>();

/// ACP Server 实例；初始化失败（未注册）时为 `null`。
ACPServerService? get acpServerOrNull =>
    getIt.isRegistered<ACPServerService>() ? getIt<ACPServerService>() : null;

/// 权限服务实例；初始化失败（未注册）时为 `null`。
PermissionService? get permissionServiceOrNull =>
    getIt.isRegistered<PermissionService>() ? getIt<PermissionService>() : null;
