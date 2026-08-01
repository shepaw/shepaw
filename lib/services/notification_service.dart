import 'dart:io' show Platform;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'logger_service.dart';

/// Singleton wrapping flutter_local_notifications.
/// Handles plugin init, permission requests, show/cancel notifications.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// 通知点击回调，payload 为通知携带的数据
  void Function(String? payload)? _onTap;
  final List<void Function(String? payload)> _tapHandlers = [];

  /// 注册通知点击回调（覆盖式，兼容旧调用方）。
  /// 在 [init] 之前或之后调用均可——回调会在点击时触发。
  void setOnNotificationTap(void Function(String? payload) handler) {
    _onTap = handler;
  }

  /// 追加通知点击回调（多订阅者；与 [setOnNotificationTap] 一并触发）。
  void addNotificationTapHandler(void Function(String? payload) handler) {
    _tapHandlers.add(handler);
  }

  void _dispatchTap(String? payload) {
    _onTap?.call(payload);
    for (final h in List.of(_tapHandlers)) {
      h(payload);
    }
  }

  /// Whether the current platform supports flutter_local_notifications.
  bool get _platformSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isLinux;

  /// Android notification channel for agent messages.
  static const _androidChannel = AndroidNotificationChannel(
    'agent_messages',
    'Agent Messages',
    description: 'Notifications for incoming agent messages',
    importance: Importance.high,
  );

  /// Android notification channel for agent approval requests.
  static const approvalsChannelId = 'agent_approvals';
  static const _approvalsChannel = AndroidNotificationChannel(
    approvalsChannelId,
    'Agent Approvals',
    description: 'Notifications when an agent needs your review',
    importance: Importance.high,
  );

  /// Initialize the notification plugin. Safe to call multiple times.
  Future<void> init() async {
    if (_initialized || !_platformSupported) return;

    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwinInit = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const initSettings = InitializationSettings(
        android: androidInit,
        iOS: darwinInit,
        macOS: darwinInit,
      );

      await _plugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: (details) {
          _dispatchTap(details.payload);
        },
      );

      // Create the Android notification channels.
      if (Platform.isAndroid) {
        final androidPlugin =
            _plugin.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        await androidPlugin?.createNotificationChannel(_androidChannel);
        await androidPlugin?.createNotificationChannel(_approvalsChannel);
      }

      _initialized = true;
    } catch (e) {
      // Plugin not available (e.g. hot-reload after adding the native dep).
      // Notifications will be silently disabled until a full restart.
      LoggerService().warning('Init failed (full rebuild needed?)', tag: 'Notification', error: e);
    }
  }

  /// Request notification permission from the OS.
  /// Returns true if granted.
  Future<bool> requestPermission() async {
    if (!_platformSupported) return false;

    if (Platform.isAndroid) {
      final androidPlugin =
          _plugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      final granted = await androidPlugin?.requestNotificationsPermission();
      return granted ?? false;
    }

    if (Platform.isIOS) {
      final iosPlugin =
          _plugin.resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>();
      final granted = await iosPlugin?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return granted ?? false;
    }

    if (Platform.isMacOS) {
      final macPlugin =
          _plugin.resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>();
      final granted = await macPlugin?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return granted ?? false;
    }

    return false;
  }

  /// Whether the OS currently allows this app to show notifications.
  ///
  /// Returns `true` on unsupported platforms (web / desktop without plugin)
  /// so settings UI does not show a misleading "enable in system" banner.
  Future<bool> areNotificationsEnabled() async {
    if (!_platformSupported) return true;

    try {
      if (Platform.isAndroid) {
        final androidPlugin =
            _plugin.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        final enabled = await androidPlugin?.areNotificationsEnabled();
        if (enabled != null) return enabled;
      }

      if (Platform.isIOS) {
        final iosPlugin =
            _plugin.resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>();
        final options = await iosPlugin?.checkPermissions();
        if (options != null) {
          return options.isEnabled ||
              options.isAlertEnabled ||
              options.isBadgeEnabled ||
              options.isSoundEnabled;
        }
      }

      if (Platform.isMacOS) {
        final macPlugin =
            _plugin.resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin>();
        final options = await macPlugin?.checkPermissions();
        if (options != null) {
          return options.isEnabled ||
              options.isAlertEnabled ||
              options.isBadgeEnabled ||
              options.isSoundEnabled;
        }
      }

      // Fallback (also covers Android API gaps).
      if (Platform.isAndroid || Platform.isIOS) {
        final status = await Permission.notification.status;
        return status.isGranted || status.isLimited || status.isProvisional;
      }
    } catch (e) {
      LoggerService().warning(
        'areNotificationsEnabled failed',
        tag: 'Notification',
        error: e,
      );
    }
    return true;
  }

  /// Opens the system settings page for this app so the user can enable
  /// notification permission (used when the OS dialog can no longer be shown).
  Future<bool> openSystemSettings() async {
    try {
      return await openAppSettings();
    } catch (e) {
      LoggerService().warning(
        'openSystemSettings failed',
        tag: 'Notification',
        error: e,
      );
      return false;
    }
  }

  /// Show a local notification.
  /// [id] is used for dedup — same id replaces the previous notification.
  /// [payload] is passed to tap handlers ([setOnNotificationTap] /
  /// [addNotificationTapHandler]) when tapped.
  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    bool playSound = true,
    String? payload,
    String? channel,
  }) async {
    if (!_initialized || !_platformSupported) return;

    final useApprovals = channel == approvalsChannelId;
    final androidChannel = useApprovals ? _approvalsChannel : _androidChannel;

    final androidDetails = AndroidNotificationDetails(
      androidChannel.id,
      androidChannel.name,
      channelDescription: androidChannel.description,
      importance: Importance.high,
      priority: Priority.high,
      playSound: playSound,
    );

    final darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: playSound,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );

    await _plugin.show(id, title, body, details, payload: payload);
  }

  /// Cancel a specific notification by id.
  Future<void> cancelNotification(int id) async {
    if (!_initialized || !_platformSupported) return;
    await _plugin.cancel(id);
  }

  /// Cancel all notifications.
  Future<void> cancelAll() async {
    if (!_initialized || !_platformSupported) return;
    await _plugin.cancelAll();
  }
}
