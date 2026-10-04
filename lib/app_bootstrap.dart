import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/widgets.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'services/local_database_service.dart';
import 'services/permission_service.dart';
import 'services/acp_server_service.dart';
import 'services/notification_service.dart';
import 'services/update_notification_service.dart';
import 'services/app_lifecycle_service.dart';
import 'services/network_monitor_service.dart';
import 'services/channel_tunnel_service.dart';
import 'services/cli_host.dart';
import 'services/cli_tool_registry.dart';
import 'clis/shepaw/shepaw_cli.dart';
import 'services/logger_service.dart';
import 'services/frame_timing_monitor.dart';
import 'services/foreground_task_service.dart';
import 'peer/services/peer_connection_manager.dart';
import 'peer/services/peer_agent_client_service.dart';
import 'peer/pouch_duties.dart';
import 'storage/pouch_login.dart';
import 'storage/pouch_login_keeper.dart';
import 'storage/pouch_role.dart';
import 'storage/pouch_session.dart';
import 'storage/store_service.dart';
import 'services/approval/pending_approval_hub.dart';
import 'services/approval/pending_approval_item.dart';
import 'services/approval/approval_reachability_notifier.dart';
import 'services/chat_navigation_service.dart';
import 'screens/storage_directory_opener.dart';
import 'services/composer_draft_service.dart';
import 'services/task/plan_approval_service.dart';
import 'service_locator.dart';
import 'services/event/setup_event_bus.dart';

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

    // 慢帧埋点：只写超预算的帧，日志页可导出（真机性能问题只能靠现场数据）
    FrameTimingMonitor().start();

    // App 不是储物袋主机。身份在登录的那只袋子里。
    // 登录态还在时先装上通道密钥，后面的重连才会用 token 密封业务帧。
    PouchDutyState.bind(const PouchRole.absent());
    await _restorePouchLogin();
    await _initializeLocalStorage();
    await _initializePeerConnection();

    // 自动建立 Channel 隧道（若已配置 autoConnect）。
    // 隧道是 P2P 跨网中转的前提：PC 需主动维护到 channel server 的隧道，
    // 外网 peer 才能经 channel server 连入本机。此前隧道仅在用户打开「设置页」
    // 或「配对二维码页」时才启动，导致 App 启动后若未进入这些页面，隧道一直
    // 离线、外网 peer 连不上。这里在启动时统一拉起。
    await _initializeChannelTunnel();

    // 初始化通知与生命周期相关服务
    AppLifecycleService().init();
    AppLifecycleService().onLock.listen((_) {
      PouchChannel.clear();
    });
    AppLifecycleService().onResume.listen((_) {
      unawaited(_restorePouchLogin());
    });
    // 监听网络变化：切网后主动重连隧道与 P2P 连接，避免半开连接拖到活性超时
    NetworkMonitorService().init();
    await NotificationService().init();
    UpdateNotificationService().init(navigatorKey: navigatorKey);
    ChatNavigationService.instance.init(navigatorKey: navigatorKey);
    registerStorageDirectoryOpener();
    _wirePlanApprovalReachability();
    if (getIt.isRegistered<ComposerDraftService>()) {
      await getIt<ComposerDraftService>().restoreFromDisk();
    }
    await PendingApprovalHub.instance.hydrate();
    ApprovalReachabilityNotifier.instance.init(navigatorKey: navigatorKey);
    ForegroundTaskService().init();

    // 本机只留 os / help。惜宝、模型和技能在登录的那台主机上。
    await CliToolRegistry.instance.initialize();
    ShepawCLI.instance.reloadExternalTools();

    return const BootstrapResult();
  }

  /// Wire [PlanApprovalService] Completer registry into [PendingApprovalHub].
  static void _wirePlanApprovalReachability() {
    final plans = PlanApprovalService.instance;
    plans.onPending = (handle) {
      final workflowId = handle.planData['_workflowId'] as String?;
      PendingApprovalHub.instance.upsert(
        PendingApprovalItem(
          id: workflowId != null
              ? PendingApprovalItem.planId(workflowId)
              : PendingApprovalItem.fallbackId(
                  kind: PendingApprovalKind.plan,
                  channelId: handle.channelId,
                  messageId: handle.messageId,
                  agentId: handle.agentId,
                ),
          channelId: handle.channelId,
          messageId: handle.messageId,
          agentId: handle.agentId,
          agentName: handle.agentName,
          kind: PendingApprovalKind.plan,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    };
    plans.onResolved = (handle) {
      final workflowId = handle.planData['_workflowId'] as String?;
      if (workflowId != null) {
        PendingApprovalHub.instance.resolveByWorkflowId(workflowId);
      } else {
        PendingApprovalHub.instance.resolve(
          PendingApprovalItem.fallbackId(
            kind: PendingApprovalKind.plan,
            channelId: handle.channelId,
            messageId: handle.messageId,
            agentId: handle.agentId,
          ),
        );
      }
    };
  }

  /// Windows/Linux 平台初始化 FFI 数据库工厂。
  static void _initDatabaseFactory() {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  /// 手机和电脑同一条：过期或没有 token 就不装通道，启动页会去登录袋子。
  static Future<void> _restorePouchLogin() async {
    try {
      final session = await PouchSessionStore.readActive();
      if (session != null &&
          session.isLoggedIn(DateTime.now().millisecondsSinceEpoch)) {
        PouchChannel.install(session);
        _log.info('Pouch login restored for ${session.pouchId}', tag: 'App');
      } else {
        PouchChannel.clear();
      }
    } catch (e) {
      PouchChannel.clear();
      _log.error('Pouch login restore failed', tag: 'App', error: e);
    }
  }

  /// 初始化本地界面库。不种示例 Agent，也不把这台 App 当成袋子。
  static Future<void> _initializeLocalStorage() async {
    try {
      _log.info('Initializing local storage...', tag: 'App');

      final db = LocalDatabaseService();
      await db.database;

      await setupEventBusAfterDb();

      _log.info('Local storage initialized', tag: 'App');
    } catch (e) {
      _log.error('Local storage initialization failed', tag: 'App', error: e);
    }
  }

  /// 只作为主机的客户端：连上去、收名单、应答存储帧。
  static Future<void> _initializePeerConnection() async {
    try {
      CliHost.installLookup();
      await PeerConnectionManager.instance.start();
      PouchLoginKeeper.instance.start();
      await PeerAgentClientService.instance.start();
      await StoreService.instance.start();
      _log.info('P2P client started', tag: 'App');
    } catch (e) {
      _log.error('P2P connection manager start failed', tag: 'App', error: e);
    }
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
        _log.info('Channel tunnel auto-start skipped (no config / disabled)',
            tag: 'App');
      }
    } catch (e) {
      _log.error('Channel tunnel auto-start failed', tag: 'App', error: e);
    }
  }
}
