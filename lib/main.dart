import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'l10n/app_localizations.dart';
import 'services/app_paths.dart';
import 'services/cli_bundle.dart';
import 'services/cli_host.dart';
import 'services/cli_language.dart';
import 'services/desktop_window_auto_size.dart';
import 'services/permission_service.dart';
import 'peer/services/closed_socket.dart';
import 'peer/services/peer_connection_manager.dart';
import 'services/logger_service.dart';
import 'services/route_gate.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'sub_window_app.dart';
import 'app_bootstrap.dart';
import 'service_locator.dart';
import 'services/app_lock_coordinator.dart';
import 'services/app_lock_service.dart';
import 'storage/pouch_session.dart';
import 'theme/app_theme.dart';
import 'widgets/compact_build_error.dart';

import 'providers/locale_provider.dart';
import 'providers/notification_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/password_setup_screen.dart';
import 'screens/login_screen.dart';
import 'screens/pouch_login_screen.dart';
import 'onboarding/host_install_screen.dart';
import 'onboarding/app_lock_screen.dart';
import 'onboarding/gate_entry.dart';
import 'onboarding/unlock_screen.dart';
import 'onboarding/welcome_screen.dart';
import 'onboarding/gate_navigator.dart';
import 'onboarding/create_password_screen.dart';
import 'onboarding/setup_done_screen.dart';

import 'screens/adaptive_home_screen.dart';
import 'widgets/window_title_sync.dart';
import 'widgets/approval/pending_approval_banner.dart';
import 'widgets/pouch_relogin_banner.dart';

// 重新导出 ACP 常量，保持 settings_screen / remote_agent_detail_screen 等
// 现有 `import '../main.dart' show kAcpServer...` 的引用不受影响。
export 'app_bootstrap.dart'
    show
        kAcpServerPortKey,
        kAcpServerDefaultPort,
        kAcpServerEnabledKey,
        kAcpServerTokenKey;

Locale _resolveAppLocale(Locale? preferred) {
  if (preferred != null) return preferred;
  final system = WidgetsBinding.instance.platformDispatcher.locale;
  for (final supported in AppLocalizations.supportedLocales) {
    if (supported.languageCode == system.languageCode) {
      return supported;
    }
  }
  return const Locale('zh');
}

Future<void> main(List<String> args) async {
  // 用 runZonedGuarded 捕获 Zone 内未处理异常，必须在 ensureInitialized 之前建立 zone，
  // 确保 ensureInitialized 和 runApp 在同一个 zone 中执行。
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // 列表项构建失败时不要用默认错误占位：它会撑满视口，release 上看着像白屏。
      installCompactBuildErrorWidget();

      // 解析数据根目录（macOS 首次运行会把旧沙盒容器搬过来）。
      // 必须早于 LoggerService / 任何数据库，否则会在错误的位置建空库。
      await AppPaths.initialize();

      // Detect if this is a sub-window by checking the current engine's arguments.
      if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
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

      // 初始化窗口管理（窗口随停靠面板开合自适应宽度，见
      // DesktopWindowAutoSize.growForPanel）。子窗口不初始化——
      // SubWindowApp 自管尺寸。
      if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
        await DesktopWindowAutoSize.ensureInitialized();
      }

      // 初始化服务定位器（注册 navigatorKey 等核心对象）
      setupServiceLocator();

      // 初始化日志服务（最先初始化，确保后续日志可写入文件）
      await LoggerService().initialize();

      if (CliHost.localCliSupported) {
        try {
          final bundled = await CliBundle.sync();
          if (bundled.warning != null) {
            LoggerService().warning(
              'cli bundle path: ${bundled.warning}',
              tag: 'CliBundle',
            );
          }
        } catch (error, stack) {
          LoggerService().error(
            'cli bundle sync failed',
            tag: 'CliBundle',
            error: error,
            stackTrace: stack,
          );
        }
      }

      final migrationNote = AppPaths.migrationNote;
      if (migrationNote != null) {
        LoggerService().info(migrationNote, tag: 'AppPaths');
      }

      // 执行完整启动编排（数据库、ACP、P2P、通知、注册表等）
      final boot = await AppBootstrap.initialize(navigatorKey: navigatorKey);
      registerBootstrapServices(
        permissionService: boot.permissionService,
      );

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
        if (_recoverClosedSocket(error)) return true;
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
      if (_recoverClosedSocket(error)) return;
      LoggerService().error(
        'Uncaught zone error',
        tag: 'Zone',
        error: error,
        stackTrace: stack,
      );
    },
  );
}

/// TLS socket 在读事件已经排队后被关掉时，异常不会进 WebSocket 的 onDone。
/// 记一条警告并丢掉已经关掉的 peer 连接，让工作流页能重连后重新加载。
bool _recoverClosedSocket(Object error) {
  if (!isReadingClosedSocket(error)) return false;
  LoggerService().warning(
    'TLS socket closed while a read was pending; dropping dead peer transports',
    tag: 'Zone',
  );
  unawaited(PeerConnectionManager.instance.dropClosedTransports());
  return true;
}

/// Run the lightweight sub-window app.
Future<void> _runSubWindow(String rawArgs) async {
  final params = jsonDecode(rawArgs) as Map<String, dynamic>;
  final key = params['key'] as String? ?? '';
  final title = params['title'] as String? ?? '';
  final locale = params['locale'] as String?;
  final themeMode = params['themeMode'] as String?;

  // Sub-windows read logs from disk / SQLite, not the main isolate's memory.
  if (key == 'system_log') {
    await LoggerService().initialize();
  }

  runApp(SubWindowApp(
    windowKey: key,
    title: title,
    localeCode: locale,
    themeMode: themeMode,
  ));
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription<PermissionRequest>? _permissionSub;
  AppLifecycleListener? _lifecycle;
  late final AppLockService _lock = getIt<AppLockService>();
  late final AppLockCoordinator _lockCoordinator;

  @override
  void initState() {
    super.initState();
    _listenForPermissionRequests();
    _listenForLock();
  }

  /// 应用锁：冷启动和回前台超过阈值都要先验证身份。
  ///
  /// 只在有登录态时才上锁 —— 还没登录过的门页本来没什么可保护的。
  void _listenForLock() {
    _lockCoordinator = AppLockCoordinator(
      lock: _lock,
      hasSession: () async => await PouchSessionStore.readActive() != null,
      onGate: () => RouteGateObserver.onGate.value,
      pushLockScreen: () async {
        final context = navigatorKey.currentContext;
        if (context == null) return;
        await Navigator.of(context).pushNamed('/app-locked');
      },
    );
    _lock.addListener(_onLockStateChanged);
    RouteGateObserver.onGate.addListener(_onLockStateChanged);
    unawaited(_lockCoordinator.start());
    _lifecycle = AppLifecycleListener(
      onHide: () => _lock.onPaused(),
      onPause: () => _lock.onPaused(),
      onResume: () {
        _lock.onResumed();
        _onLockStateChanged();
      },
    );
  }

  void _onLockStateChanged() {
    if (!mounted) return;
    unawaited(_lockCoordinator.check());
  }

  void _listenForPermissionRequests() {
    final service = permissionServiceOrNull;
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
              _buildInfoRow(AppLocalizations.of(ctx).permissionDialog_agent,
                  request.agentName),
              const SizedBox(height: 8),
              _buildInfoRow(AppLocalizations.of(ctx).permissionDialog_action,
                  request.permissionType.name),
              const SizedBox(height: 8),
              _buildInfoRow(AppLocalizations.of(ctx).permissionDialog_reason,
                  request.reason),
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
              child: Text(AppLocalizations.of(ctx).permissionDialog_reject,
                  style: const TextStyle(color: Colors.red)),
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
    _lock.removeListener(_onLockStateChanged);
    RouteGateObserver.onGate.removeListener(_onLockStateChanged);
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => LocaleProvider(),
        ),
        ChangeNotifierProvider(
          create: (_) => ThemeProvider(),
        ),
        ChangeNotifierProvider(
          create: (_) => NotificationProvider(),
        ),
      ],
      child: Consumer2<LocaleProvider, ThemeProvider>(
        builder: (context, localeProvider, themeProvider, _) {
          final l10n = lookupAppLocalizations(
            _resolveAppLocale(localeProvider.locale),
          );
          return WithForegroundTask(
            child: MaterialApp(
              navigatorKey: navigatorKey,
              navigatorObservers: [RouteGateObserver.instance],
              title: l10n.appTitle,
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
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: themeProvider.themeMode,
              builder: (context, child) {
                if (localeProvider.ready) {
                  final code =
                      Localizations.maybeLocaleOf(context)?.languageCode;
                  if (code != null) {
                    unawaited(CliLanguage.sync(code));
                  }
                }
                return WindowTitleSync(
                  child: PouchReloginBanner(
                    child: PendingApprovalBanner(
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ),
                );
              },
              home: const SplashScreen(),
              routes: {
                '/setup': (context) => const PasswordSetupScreen(),
                '/login': (context) => const LoginScreen(),
                '/pouch': (context) => const PouchLoginScreen(),
                '/welcome': (context) => const WelcomeScreen(),
                '/host-install': (context) => const HostInstallScreen(),
                '/create-password': (context) => const CreatePasswordScreen(),
                '/setup-done': (context) => const SetupDoneScreen(),
                '/host-setup': (context) => const WelcomeScreen(),
                '/pouch-init': (context) => const CreatePasswordScreen(),
                '/pouch-unlock': (context) => const _LegacyUnlockRoute(),
                '/unlock': (context) => const UnlockScreen(),
                '/app-locked': (context) => AppLockScreen(lock: _lock),
                '/remote-connect': (context) => const WelcomeScreen(),
                '/phone-login': (context) => const _LegacyUnlockRoute(),
                '/home': (context) => const AdaptiveHomeScreen(),
              },
            ),
          );
        },
      ),
    );
  }
}

/// 启动页 - 检查密码状态并导航到相应页面
/// 旧门页的别名：把 `/phone-login`、`/pouch-unlock` 转到新的 `/unlock`。
///
/// L6 清路由时连这个类一起删。
class _LegacyUnlockRoute extends StatelessWidget {
  const _LegacyUnlockRoute();

  @override
  Widget build(BuildContext context) {
    final raw = ModalRoute.of(context)?.settings.arguments;
    final hostPeerId = raw is UnlockArgs ? raw.hostPeerId : '';
    return UnlockScreen(
      args: UnlockArgs(hostPeerId: hostPeerId),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({Key? key}) : super(key: key);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final _phase = ValueNotifier<GatePhase>(GatePhase.starting);

  @override
  void initState() {
    super.initState();
    _checkPasswordStatus();
  }

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  /// 门在哪、要不要静默续期，全部交给 [GateNavigator]。
  ///
  /// 这里只保证启动页不会闪一下：离开之前至少停 300ms，其余时间都拿去干活，
  /// 不再固定等 1 秒。
  Future<void> _checkPasswordStatus() async {
    if (!mounted) return;
    await GateNavigator.go(
      context,
      minDisplay: const Duration(milliseconds: 300),
      phase: _phase,
    );
  }

  String _status(AppLocalizations l10n) {
    return switch (_phase.value) {
      GatePhase.starting => l10n.gate_splashStarting,
      GatePhase.startingHost => l10n.gate_splashStartingHost,
      GatePhase.connecting => l10n.gate_splashConnecting(l10n.appTitle),
      GatePhase.restoring => l10n.gate_splashRestoring,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: AppTheme.brandGradient,
        ),
        child: Center(
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
              Text(
                l10n.appTitle,
                style: const TextStyle(
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

              ValueListenableBuilder<GatePhase>(
                valueListenable: _phase,
                builder: (context, _, __) => Text(
                  _status(l10n),
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.white70,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
