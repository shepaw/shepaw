import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'l10n/app_localizations.dart';
import 'services/password_service.dart';
import 'services/local_database_service.dart';
import 'services/local_api_service.dart';
import 'services/local_storage_service.dart';
import 'services/permission_service.dart';
import 'services/acp_server_service.dart';
import 'services/remote_agent_service.dart';
import 'services/token_service.dart';
import 'services/notification_service.dart';
import 'services/update_notification_service.dart';
import 'services/app_lifecycle_service.dart';
import 'services/skill_registry.dart';
import 'services/cli_tool_registry.dart';
import 'clis/shepaw/shepaw_cli.dart';
import 'services/model_registry.dart';
import 'services/logger_service.dart';
import 'services/foreground_task_service.dart';
import 'task/services/scheduled_task_service.dart';
import 'services/trace_service.dart';
import 'services/channel_tunnel_service.dart';
import 'peer/services/peer_connection_manager.dart';
import 'services/she_service.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'sub_window_app.dart';

import 'models/message.dart';
import 'providers/app_state.dart';
import 'providers/locale_provider.dart';
import 'providers/notification_provider.dart';
import 'screens/password_setup_screen.dart';
import 'screens/login_screen.dart';
import 'screens/adaptive_home_screen.dart';
// 全局 ACP Server 实例
late ACPServerService globalACPServer;

/// ACP Server 端口的 SharedPreferences 键
const kAcpServerPortKey = 'acp_server_port';
const kAcpServerDefaultPort = 18790;
/// ACP Server 是否启用的 SharedPreferences 键（默认开启）
const kAcpServerEnabledKey = 'acp_server_enabled';
/// ACP Server 连接 Token 的 SharedPreferences 键
const kAcpServerTokenKey = 'acp_server_token';

// 全局 Navigator Key（用于在任意位置弹出对话框）
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// 全局 PermissionService 引用
PermissionService? globalPermissionService;

Future<void> main(List<String> args) async {
  // 用 runZonedGuarded 捕获 Zone 内未处理异常，必须在 ensureInitialized 之前建立 zone，
  // 确保 ensureInitialized 和 runApp 在同一个 zone 中执行。
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Detect if this is a sub-window by checking the current engine's arguments.
      if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
        try {
          final windowController = await WindowController.fromCurrentEngine();
          final windowArgs = windowController.arguments;
          if (windowArgs.isNotEmpty) {
            // This is a sub-window — run the lightweight sub-window app.
            await _runSubWindow(windowArgs);
            return;
          }
        } catch (_) {
          // Not a sub-window (main window) — continue normal startup.
        }
      }

      // --- Main window startup ---

      // Web/Windows平台初始化FFI数据库工厂
      if (kIsWeb) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfiWeb;
      } else if (Platform.isWindows || Platform.isLinux) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }

      // 初始化日志服务（最先初始化，确保后续日志可写入文件）
      await LoggerService().initialize();

      // 初始化本地数据库
      await _initializeLocalStorage();

      // 检查远端 Agent 健康状态
      await _checkRemoteAgentsHealth();

      // 初始化 She（内置守护 Agent）
      await SheService.instance.ensureSheExists();

      // 初始化 ACP Server
      await _initializeACPServer();

      // 自动启动 Channel Tunnel（如有本地 agent 配置了公网穿透）
      await _initializeChannelTunnel();

      // 启动 P2P 连接管理器（后台监听入站连接、自动重连已配对设备）
      await _initializePeerConnection();

      // Initialize notification and lifecycle services
      AppLifecycleService().init();
      await NotificationService().init();
      UpdateNotificationService().init(navigatorKey: navigatorKey);
      ForegroundTaskService().init();
      // Initialize scheduled task service
      await ScheduledTaskService().startScheduler();

      // Initialize skill registry
      await SkillRegistry.instance.initialize();

      // Initialize external CLI tool registry and load into ShepawCLI
      await CliToolRegistry.instance.initialize();
      ShepawCLI.instance.reloadExternalTools();

      // Initialize tool model registry
      await ModelRegistry.instance.initialize();

      // Initialize trace database and run retention cleanup
      await TraceService.instance.cleanup();

      // 捕获 Flutter 框架异常
      FlutterError.onError = (details) {
        LoggerService().error(
          'Flutter framework error: ${details.exceptionAsString()}',
          tag: 'Flutter',
          error: details.exception,
          stackTrace: details.stack,
        );
      };

      // 捕获未处理的异步异常
      PlatformDispatcher.instance.onError = (error, stack) {
        LoggerService().error(
          'Unhandled async error',
          tag: 'Platform',
          error: error,
          stackTrace: stack,
        );
        return true;
      };

      runApp(const MyApp());
    },
    (error, stack) {
      LoggerService().error(
        'Uncaught zone error',
        tag: 'Zone',
        error: error,
        stackTrace: stack,
      );
    },
  );
}

/// Run the lightweight sub-window app.
Future<void> _runSubWindow(String rawArgs) async {
  final params = jsonDecode(rawArgs) as Map<String, dynamic>;
  final key = params['key'] as String? ?? '';
  final title = params['title'] as String? ?? '';
  final locale = params['locale'] as String?;

  // For system log, initialize LoggerService so disk-persisted logs are available.
  if (key == 'system_log') {
    await LoggerService().initialize();
  }

  runApp(SubWindowApp(
    windowKey: key,
    title: title,
    localeCode: locale,
  ));
}
/// 初始化本地存储
Future<void> _initializeLocalStorage() async {
  final _log = LoggerService();
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
Future<void> _checkRemoteAgentsHealth() async {
  final _log = LoggerService();
  try {
    _log.info('Checking remote agents health...', tag: 'App');

    final databaseService = LocalDatabaseService();
    final tokenService = TokenService(databaseService);
    final remoteAgentService = RemoteAgentService(databaseService, tokenService);

    // 检查所有 Agent 的健康状态
    final onlineCount = await remoteAgentService.checkAllAgentsHealth(
      timeout: const Duration(seconds: 3),
    );

    _log.info('Remote agents health check done, online: $onlineCount', tag: 'App');
  } catch (e) {
    _log.error('Remote agents health check failed', tag: 'App', error: e);
  }
}

/// 初始化 ACP Server
Future<void> _initializeACPServer() async {
  final _log = LoggerService();
  try {
    _log.info('Initializing ACP Server...', tag: 'App');

    // 创建服务实例
    final storageService = LocalStorageService();
    final permissionService = PermissionService(storageService);
    final apiService = LocalApiService();

    // 初始化权限数据库
    await permissionService.initialize();

    // 保存全局引用
    globalPermissionService = permissionService;

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

    // 创建 ACP Server
    globalACPServer = ACPServerService(
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

    // Handle ui.fileMessage notifications from inbound Agents
    globalACPServer.onFileMessage = (agentId, agentName, params) async {
      try {
        final url = params['url'] as String?;
        final filename = params['filename'] as String?;
        final mimeType = params['mime_type'] as String?;
        final size = params['size'] as int?;
        final thumbnailBase64 = params['thumbnail_base64'] as String?;
        final fileId = params['file_id'] as String?;

        // 需要至少有 url 或 file_id 之一
        if ((url == null || url.isEmpty) && (fileId == null || fileId.isEmpty)) {
          _log.warning('ui.fileMessage missing url and file_id from $agentName', tag: 'ACPServer');
          return;
        }

        // 从 HTTP url 路径中提取 file_id（兼容 http://host/files/{id} 格式）
        String? resolvedFileId = fileId;
        if (resolvedFileId == null && url != null && url.isNotEmpty) {
          try {
            final uri = Uri.parse(url);
            if (uri.pathSegments.length >= 2 &&
                uri.pathSegments[uri.pathSegments.length - 2] == 'files') {
              resolvedFileId = uri.pathSegments.last;
            }
          } catch (_) {}
        }

        final isImage = mimeType != null && mimeType.startsWith('image/');
        final msgType = isImage ? MessageType.image : MessageType.file;

        final metadata = <String, dynamic>{
          'name': filename ?? 'file',
          'type': mimeType ?? 'application/octet-stream',
          'size': size ?? 0,
          'download_status': 'pending',
        };

        if (url != null && url.isNotEmpty) metadata['source_url'] = url;
        if (resolvedFileId != null) metadata['file_id'] = resolvedFileId;
        if (thumbnailBase64 != null && thumbnailBase64.isNotEmpty) {
          metadata['thumbnail_base64'] = thumbnailBase64;
        }

        final databaseService = LocalDatabaseService();
        final channelId = params['channel_id'] as String? ?? '';
        final messageId = 'file_${DateTime.now().millisecondsSinceEpoch}';

        await databaseService.createMessage(
          id: messageId,
          channelId: channelId,
          senderId: agentId,
          senderType: 'agent',
          senderName: agentName,
          content: isImage ? '[Image: ${filename ?? "image"}]' : '[File: ${filename ?? "file"}]',
          messageType: msgType.toString().split('.').last,
          metadata: metadata,
        );

        _log.info('File message saved (pending) from $agentName: ${filename ?? "file"}', tag: 'ACPServer');

        _maybeShowFileNotification(
          channelId: channelId,
          senderId: agentId,
          senderName: agentName,
          content: isImage ? '[Image: ${filename ?? "image"}]' : '[File: ${filename ?? "file"}]',
        );
      } catch (e) {
        _log.error('Failed to handle file message', tag: 'ACPServer', error: e);
      }
    };

    // 启动服务器（仅当用户开启了本地服务开关时）
    final enabled = prefs.getBool(kAcpServerEnabledKey) ?? true;
    if (enabled) {
      await globalACPServer.start();
      _log.info('ACP Server started (port: $port)', tag: 'App');
    } else {
      _log.info('ACP Server disabled by user, skipping start', tag: 'App');
    }
  } catch (e) {
    _log.error('ACP Server initialization failed', tag: 'App', error: e);
  }
}

/// 自动启动 Channel Tunnel
/// 扫描所有本地 agent，找到第一个 allowExternalAccess=true 且配置了 channelConfig 的
/// agent，用其配置启动隧道。
Future<void> _initializeChannelTunnel() async {
  final log = LoggerService();
  try {
    final db = LocalDatabaseService();
    final tokenService = TokenService(db);
    final agentService = RemoteAgentService(db, tokenService);
    final allAgents = await agentService.getAllAgents();
    for (final agent in allAgents) {
      final cfg = agent.channelConfig;
      if (cfg != null && agent.allowExternalAccess) {
        log.info(
          'Auto-starting channel tunnel for agent "${agent.name}" (channel_id=${cfg.channelId})',
          tag: 'App',
        );
        await ChannelTunnelService.instance.startWithConfig(cfg);
        return;
      }
    }
    log.debug('No agent with channel tunnel config found, skipping', tag: 'App');
  } catch (e) {
    log.error('Channel tunnel auto-start failed', tag: 'App', error: e);
  }
}

NotificationProvider? _globalNotificationProvider;

/// 启动 P2P 连接管理器
Future<void> _initializePeerConnection() async {
  final log = LoggerService();
  try {
    await PeerConnectionManager.instance.start();
    log.info('P2P connection manager started', tag: 'App');
  } catch (e) {
    log.error('P2P connection manager start failed', tag: 'App', error: e);
  }
}

void setGlobalNotificationProvider(NotificationProvider provider) {
  _globalNotificationProvider = provider;
}

/// Fire a local notification for an inbound file message (written directly
/// to DB, bypassing ChatService).
void _maybeShowFileNotification({
  required String channelId,
  required String senderId,
  required String senderName,
  required String content,
}) {
  final provider = _globalNotificationProvider;
  if (provider == null) return;
  if (!provider.shouldNotify(senderId)) return;
  if (AppLifecycleService().shouldSuppressNotification(channelId)) return;

  final body = provider.showPreview ? content : 'New message';
  NotificationService().showNotification(
    id: channelId.hashCode,
    title: senderName,
    body: body,
    playSound: provider.soundEnabled,
  );
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription<PermissionRequest>? _permissionSub;

  @override
  void initState() {
    super.initState();
    _listenForPermissionRequests();
  }

  void _listenForPermissionRequests() {
    final service = globalPermissionService;
    if (service == null) return;

    _permissionSub = service.pendingRequestStream.listen((request) {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return;

      showDialog(
        context: ctx,
        barrierDismissible: false,
        builder: (dialogCtx) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.security, color: Colors.orange),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  AppLocalizations.of(ctx).permissionDialog_title,
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInfoRow(AppLocalizations.of(ctx).permissionDialog_agent, request.agentName),
              const SizedBox(height: 8),
              _buildInfoRow(AppLocalizations.of(ctx).permissionDialog_action, request.permissionType.name),
              const SizedBox(height: 8),
              _buildInfoRow(AppLocalizations.of(ctx).permissionDialog_reason, request.reason),
              const SizedBox(height: 8),
              _buildInfoRow(
                AppLocalizations.of(ctx).permissionDialog_time,
                '${request.requestTime.hour.toString().padLeft(2, '0')}:'
                '${request.requestTime.minute.toString().padLeft(2, '0')}:'
                '${request.requestTime.second.toString().padLeft(2, '0')}',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                service.rejectPermission(request.id);
                Navigator.of(dialogCtx).pop();
              },
              child: Text(AppLocalizations.of(ctx).permissionDialog_reject, style: const TextStyle(color: Colors.red)),
            ),
            ElevatedButton(
              onPressed: () {
                service.approvePermission(request.id);
                Navigator.of(dialogCtx).pop();
              },
              child: Text(AppLocalizations.of(ctx).permissionDialog_approve),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 60,
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: Colors.grey,
            ),
          ),
        ),
        Expanded(
          child: Text(value, style: const TextStyle(fontSize: 13)),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _permissionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AppState(),
        ),
        ChangeNotifierProvider(
          create: (_) => LocaleProvider(),
        ),
        ChangeNotifierProvider(
          create: (_) => NotificationProvider(),
        ),
      ],
      child: Consumer<LocaleProvider>(
        builder: (context, localeProvider, _) => WithForegroundTask(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            title: 'Paw',
            debugShowCheckedModeBanner: false,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: localeProvider.locale,
            localeResolutionCallback: (locale, supportedLocales) {
              for (final supportedLocale in supportedLocales) {
                if (supportedLocale.languageCode == locale?.languageCode) {
                  return supportedLocale;
                }
              }
              return const Locale('zh');
            },
            theme: ThemeData(
              primarySwatch: Colors.blue,
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.blue,
                brightness: Brightness.light,
              ),
            ),
            home: const SplashScreen(),
            routes: {
              '/setup': (context) => const PasswordSetupScreen(),
              '/login': (context) => const LoginScreen(),
              '/home': (context) => const AdaptiveHomeScreen(),
            },
          ),
        ),
      ),
    );
  }
}

/// 启动页 - 检查密码状态并导航到相应页面
class SplashScreen extends StatefulWidget {
  const SplashScreen({Key? key}) : super(key: key);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final _passwordService = PasswordService();

  @override
  void initState() {
    super.initState();
    _checkPasswordStatus();
  }

  Future<void> _checkPasswordStatus() async {
    // 短暂延迟，显示启动画面
    await Future.delayed(const Duration(seconds: 1));
    
    if (!mounted) return;
    
    // 检查是否已设置密码
    final isPasswordSet = await _passwordService.isPasswordSet();
    
    if (isPasswordSet) {
      // 已设置密码，跳转到登录页
      Navigator.of(context).pushReplacementNamed('/login');
    } else {
      // 未设置密码，跳转到设置页
      Navigator.of(context).pushReplacementNamed('/setup');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).primaryColor,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Logo
            ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: Image.asset(
                'assets/images/shepaw_icon.png',
                width: 120,
                height: 120,
              ),
            ),
            const SizedBox(height: 32),
            
            // 应用名称
            const Text(
              'Paw',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),

            // 加载指示器
            const CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
            const SizedBox(height: 16),

            Text(
              AppLocalizations.of(context).splash_loading,
              style: const TextStyle(
                fontSize: 16,
                color: Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
