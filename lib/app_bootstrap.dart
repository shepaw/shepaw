import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import 'services/local_database_service.dart';
import 'services/local_api_service.dart';
import 'services/local_storage_service.dart';
import 'services/permission_service.dart';
import 'services/acp_server_service.dart';
import 'services/remote_agent_service.dart';
import 'services/notification_service.dart';
import 'services/update_notification_service.dart';
import 'services/app_lifecycle_service.dart';
import 'services/network_monitor_service.dart';
import 'services/channel_tunnel_service.dart';
import 'services/skill_registry.dart';
import 'services/cli_tool_registry.dart';
import 'clis/shepaw/shepaw_cli.dart';
import 'services/model_registry.dart';
import 'services/logger_service.dart';
import 'services/foreground_task_service.dart';
import 'task/services/scheduled_task_service.dart';
import 'services/trace_service.dart';
import 'services/chat_service.dart';
import 'peer/services/peer_connection_manager.dart';
import 'peer/services/peer_agent_host_service.dart';
import 'peer/services/peer_agent_client_service.dart';
import 'identity/services/account_join_service.dart';
import 'services/she_service.dart';
import 'service_locator.dart';

/// ACP Server 端口的 SharedPreferences 键
const kAcpServerPortKey = 'acp_server_port';
const kAcpServerDefaultPort = 18790;

/// ACP Server 是否启用的 SharedPreferences 键（默认开启）
const kAcpServerEnabledKey = 'acp_server_enabled';

/// ACP Server 连接 Token 的 SharedPreferences 键
const kAcpServerTokenKey = 'acp_server_token';

/// [AppBootstrap.initialize] 的结果，承载需要被提升为全局引用的服务实例。
///
/// 字段可空：当对应初始化步骤失败时为 `null`，由调用方决定是否赋值给全局变量。
class BootstrapResult {
  /// ACP Server 实例（即使未启动也会返回，供设置页读取运行状态）。
  final ACPServerService? acpServer;

  /// 权限服务实例。
  final PermissionService? permissionService;

  const BootstrapResult({this.acpServer, this.permissionService});
}

/// 应用启动编排器。
///
/// 把原先散落在 `main()` 里的初始化链集中到此处，使入口文件保持精简，
/// 并让各初始化步骤有清晰的归属与独立的失败兜底。每个步骤都各自捕获异常
/// 并记录日志，单步失败不会中断整体启动（与重构前行为一致）。
class AppBootstrap {
  AppBootstrap._();

  static final LoggerService _log = LoggerService();

  /// 执行主窗口的完整初始化序列，返回需要提升为全局引用的服务实例。
  ///
  /// 调用方需保证 [LoggerService] 已先行初始化（日志在初始化早期即被使用）。
  static Future<BootstrapResult> initialize({
    required GlobalKey<NavigatorState> navigatorKey,
  }) async {
    _initDatabaseFactory();

    // 初始化本地数据库与示例数据
    await _initializeLocalStorage();

    // 检查远端 Agent 健康状态
    await _checkRemoteAgentsHealth();

    // 初始化 She（内置守护 Agent）
    await SheService.instance.ensureSheExists();

    // 初始化 ACP Server
    final acp = await _initializeACPServer();

    // 启动 P2P 连接管理器
    await _initializePeerConnection();

    // 账号身份（User / SpiritPet / 设备角色）与 P2P 同步协议
    await _initializeAccountIdentity();

    // 自动建立 Channel 隧道（若已配置 autoConnect）。
    // 隧道是 P2P 跨网中转的前提：PC 需主动维护到 channel server 的隧道，
    // 外网 peer 才能经 channel server 连入本机。此前隧道仅在用户打开「设置页」
    // 或「配对二维码页」时才启动，导致 App 启动后若未进入这些页面，隧道一直
    // 离线、外网 peer 连不上。这里在启动时统一拉起。
    await _initializeChannelTunnel();

    // 初始化通知与生命周期相关服务
    AppLifecycleService().init();
    // 监听网络变化：切网后主动重连隧道与 P2P 连接，避免半开连接拖到活性超时
    NetworkMonitorService().init();
    await NotificationService().init();
    UpdateNotificationService().init(navigatorKey: navigatorKey);
    ForegroundTaskService().init();
    await ScheduledTaskService().startScheduler();

    // 初始化技能注册表
    await SkillRegistry.instance.initialize();

    // 初始化外部 CLI 工具注册表并加载进 ShepawCLI
    await CliToolRegistry.instance.initialize();
    ShepawCLI.instance.reloadExternalTools();

    // 初始化工具模型注册表
    await ModelRegistry.instance.initialize();

    // 初始化追踪数据库并执行保留期清理
    await TraceService.instance.cleanup();

    return BootstrapResult(
      acpServer: acp?.$1,
      permissionService: acp?.$2,
    );
  }

  /// Web/Windows/Linux 平台初始化 FFI 数据库工厂。
  static void _initDatabaseFactory() {
    if (kIsWeb) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiWeb;
    } else if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  /// 初始化本地存储
  static Future<void> _initializeLocalStorage() async {
    try {
      _log.info('Initializing local storage...', tag: 'App');

      // 初始化数据库
      final db = LocalDatabaseService();
      await db.database; // 触发数据库初始化

      // 初始化示例数据（仅首次启动）
      final api = LocalApiService();
      await api.initializeSampleData();

      _log.info('Local storage initialized', tag: 'App');
    } catch (e) {
      _log.error('Local storage initialization failed', tag: 'App', error: e);
    }
  }

  /// 检查远端 Agent 健康状态
  static Future<void> _checkRemoteAgentsHealth() async {
    try {
      _log.info('Checking remote agents health...', tag: 'App');

      final onlineCount = await getIt<RemoteAgentService>().checkAllAgentsHealth(
        timeout: const Duration(seconds: 3),
      );

      _log.info('Remote agents health check done, online: $onlineCount', tag: 'App');
    } catch (e) {
      _log.error('Remote agents health check failed', tag: 'App', error: e);
    }
  }

  /// 初始化 ACP Server。
  ///
  /// 成功时返回 `(server, permissionService)`，失败时返回 `null`（调用方据此
  /// 决定是否赋值全局引用，与重构前"失败则全局变量保持未赋值"的语义一致）。
  static Future<(ACPServerService, PermissionService)?> _initializeACPServer() async {
    try {
      _log.info('Initializing ACP Server...', tag: 'App');

      final storageService = LocalStorageService();
      final permissionService = PermissionService(storageService);
      final apiService = LocalApiService();

      // 初始化权限数据库
      await permissionService.initialize();

      // 读取持久化的端口配置
      final prefs = await SharedPreferences.getInstance();
      final port = prefs.getInt(kAcpServerPortKey) ?? kAcpServerDefaultPort;

      // 读取或自动生成连接 Token
      String? token = prefs.getString(kAcpServerTokenKey);
      if (token == null || token.isEmpty) {
        token = const Uuid().v4();
        await prefs.setString(kAcpServerTokenKey, token);
        _log.info('Generated new ACP Server token', tag: 'App');
      }

      final acpServer = ACPServerService(
        config: ACPServerConfig(
          host: '0.0.0.0',
          port: port,
          heartbeatInterval: 30,
          token: token,
        ),
        permissionService: permissionService,
        apiService: apiService,
        databaseService: LocalDatabaseService(),
      );

      // 入站 Agent 的 ui.fileMessage 通知交由 ChatService 走统一写入路径处理。
      acpServer.onFileMessage = (agentId, agentName, params) =>
          ChatService().handleInboundFileMessage(agentId, agentName, params);

      // 启动服务器（仅当用户开启了本地服务开关时）
      final enabled = prefs.getBool(kAcpServerEnabledKey) ?? true;
      if (enabled) {
        await acpServer.start();
        _log.info('ACP Server started (port: $port)', tag: 'App');
      } else {
        _log.info('ACP Server disabled by user, skipping start', tag: 'App');
      }

      return (acpServer, permissionService);
    } catch (e) {
      _log.error('ACP Server initialization failed', tag: 'App', error: e);
      return null;
    }
  }

  /// 启动 P2P 连接管理器
  static Future<void> _initializePeerConnection() async {
    try {
      await PeerConnectionManager.instance.start();
      // Agent-over-Peer：host 暴露本机本地 agent；client 注入配对设备 agent。
      // 两侧都启动，使任意设备既可作提供方也可作消费方。
      PeerAgentHostService.instance.start();
      await PeerAgentClientService.instance.start();
      _log.info('P2P connection manager started', tag: 'App');
    } catch (e) {
      _log.error('P2P connection manager start failed', tag: 'App', error: e);
    }
  }

  /// 启动账号加入协议监听（不依赖账号是否已登录）。
  static Future<void> _initializeAccountIdentity() async {
    AccountJoinService.instance.start();
  }

  /// 自动建立 Channel 隧道。
  ///
  /// 仅当用户已保存配置且开启 [ChannelTunnelConfig.autoConnect] 时启动。
  /// [ChannelTunnelService.startWithConfig] 自带 `isRunning` 防重入，故即便设置页
  /// 之后再次触发启动也不会重复连接。
  static Future<void> _initializeChannelTunnel() async {
    try {
      final config = await ChannelTunnelService.instance.loadConfig();
      if (config != null &&
          config.autoConnect &&
          !ChannelTunnelService.instance.isRunning) {
        await ChannelTunnelService.instance.startWithConfig(config);
        _log.info('Channel tunnel auto-started', tag: 'App');
      } else {
        _log.info('Channel tunnel auto-start skipped (no config / disabled)', tag: 'App');
      }
    } catch (e) {
      _log.error('Channel tunnel auto-start failed', tag: 'App', error: e);
    }
  }
}
