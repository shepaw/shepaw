import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'l10n/app_localizations.dart';
import 'services/password_service.dart';
import 'services/permission_service.dart';
import 'services/logger_service.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'sub_window_app.dart';
import 'app_bootstrap.dart';
import 'service_locator.dart';

import 'providers/app_state.dart';
import 'providers/locale_provider.dart';
import 'providers/notification_provider.dart';
import 'screens/password_setup_screen.dart';
import 'screens/login_screen.dart';
import 'screens/adaptive_home_screen.dart';

// 重新导出 ACP 常量，保持 settings_screen / remote_agent_detail_screen 等
// 现有 `import '../main.dart' show kAcpServer...` 的引用不受影响。
export 'app_bootstrap.dart'
    show kAcpServerPortKey, kAcpServerDefaultPort, kAcpServerEnabledKey, kAcpServerTokenKey;

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

      // 初始化服务定位器（注册 navigatorKey 等核心对象）
      setupServiceLocator();

      // 初始化日志服务（最先初始化，确保后续日志可写入文件）
      await LoggerService().initialize();

      // 执行完整启动编排（数据库、ACP、P2P、通知、注册表等）
      final boot = await AppBootstrap.initialize(navigatorKey: navigatorKey);
      registerBootstrapServices(
        acpServer: boot.acpServer,
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
