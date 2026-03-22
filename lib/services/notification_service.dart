import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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

  /// Whether the current platform supports flutter_local_notifications.
  bool get _platformSupported =>
      !kIsWeb &&
      (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isLinux);

  /// Android notification channel for agent messages.
  static const _androidChannel = AndroidNotificationChannel(
    'agent_messages',
    'Agent Messages',
    description: 'Notifications for incoming agent messages',
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

      await _plugin.initialize(initSettings);

      // Create the Android notification channel.
      if (!kIsWeb && Platform.isAndroid) {
        final androidPlugin =
            _plugin.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        await androidPlugin?.createNotificationChannel(_androidChannel);
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

  /// Show a local notification.
  /// [id] is used for dedup — same id replaces the previous notification.
  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    bool playSound = true,
  }) async {
    if (!_initialized || !_platformSupported) return;

    final androidDetails = AndroidNotificationDetails(
      _androidChannel.id,
      _androidChannel.name,
      channelDescription: _androidChannel.description,
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

    await _plugin.show(id, title, body, details);
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
