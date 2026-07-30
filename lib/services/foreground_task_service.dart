import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'logger_service.dart';

/// Keeps the app and screen alive while agent tasks are running.
///
/// Two complementary mechanisms, both driven by the same reference counts:
///
/// 1. **Screen wakelock** (iOS + Android + desktop): prevents the display from
///    auto-sleeping while a turn is in progress. Screen-off otherwise suspends
///    the process (especially on iOS) and kills ACP WebSockets → connection
///    timeout / "interrupted while in background".
/// 2. **Android foreground service**: keeps the process alive if the user
///    backgrounds the app mid-turn. No-op on other platforms.
///
/// Uses reference counting so both stay active as long as at least one agent
/// task is in progress.
class ForegroundTaskService {
  ForegroundTaskService._();
  static final ForegroundTaskService _instance = ForegroundTaskService._();
  factory ForegroundTaskService() => _instance;

  /// Per-agent reference counts. A single agent may have concurrent tasks
  /// across multiple channels.
  final Map<String, int> _activeAgentCounts = {};

  bool _initialized = false;
  bool _running = false;
  bool _screenWakelockHeld = false;

  /// Whether the Android foreground service is currently active.
  bool get isRunning => _running;

  /// True only on Android (not web).
  bool get _isAndroidFgsSupported => !kIsWeb && Platform.isAndroid;

  /// Screen wakelock is useful on any non-web platform that can sleep the
  /// display and suspend the isolate.
  bool get _isScreenWakelockSupported => !kIsWeb;

  /// Call once during app startup (after [WidgetsFlutterBinding.ensureInitialized]).
  void init() {
    if (!_isAndroidFgsSupported || _initialized) return;
    _initialized = true;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'paw_foreground_service',
        channelName: 'Agent Processing',
        channelDescription: 'Keeps the connection alive while an agent is working',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Increment the reference count for [agentName] and start keep-alive
  /// mechanisms if they are not already running.
  Future<void> acquireTask(String agentName) async {
    if (kIsWeb) return;

    _activeAgentCounts[agentName] = (_activeAgentCounts[agentName] ?? 0) + 1;
    LoggerService().debug(
      'acquire "$agentName" (count: ${_activeAgentCounts[agentName]}, '
      'total agents: ${_activeAgentCounts.length})',
      tag: 'ForegroundTask',
    );

    await _syncScreenWakelock();

    if (_isAndroidFgsSupported && !_running) {
      await _startService();
    }
  }

  /// Decrement the reference count for [agentName]. When all counts reach zero
  /// keep-alive mechanisms are stopped.
  Future<void> releaseTask(String agentName) async {
    if (kIsWeb) return;

    final current = _activeAgentCounts[agentName] ?? 0;
    if (current <= 1) {
      _activeAgentCounts.remove(agentName);
    } else {
      _activeAgentCounts[agentName] = current - 1;
    }

    LoggerService().debug(
      'release "$agentName" (count: ${_activeAgentCounts[agentName] ?? 0}, '
      'total agents: ${_activeAgentCounts.length})',
      tag: 'ForegroundTask',
    );

    await _syncScreenWakelock();

    if (_isAndroidFgsSupported && _activeAgentCounts.isEmpty && _running) {
      await _stopService();
    }
  }

  /// Emergency cleanup — release all tasks and stop keep-alive immediately.
  Future<void> releaseAllTasks() async {
    if (kIsWeb) return;

    _activeAgentCounts.clear();
    await _syncScreenWakelock();
    if (_isAndroidFgsSupported && _running) {
      await _stopService();
    }
  }

  Future<void> _syncScreenWakelock() async {
    if (!_isScreenWakelockSupported) return;

    final shouldHold = _activeAgentCounts.isNotEmpty;
    if (shouldHold == _screenWakelockHeld) return;

    try {
      if (shouldHold) {
        await WakelockPlus.enable();
        _screenWakelockHeld = true;
        LoggerService().info('Screen wakelock enabled', tag: 'ForegroundTask');
      } else {
        await WakelockPlus.disable();
        _screenWakelockHeld = false;
        LoggerService().info('Screen wakelock disabled', tag: 'ForegroundTask');
      }
    } catch (e) {
      LoggerService().error(
        'Failed to sync screen wakelock (want=$shouldHold)',
        tag: 'ForegroundTask',
        error: e,
      );
      // Leave _screenWakelockHeld unchanged so the next acquire/release retries.
    }
  }

  Future<void> _startService() async {
    try {
      _running = true;
      await FlutterForegroundTask.startService(
        notificationTitle: 'Paw - Agent Processing',
        notificationText: 'An agent task is in progress',
        callback: _foregroundTaskCallback,
      );
      LoggerService().info('Service started', tag: 'ForegroundTask');
    } catch (e) {
      LoggerService().error('Failed to start service', tag: 'ForegroundTask', error: e);
      _running = false;
    }
  }

  Future<void> _stopService() async {
    try {
      await FlutterForegroundTask.stopService();
      _running = false;
      LoggerService().info('Service stopped', tag: 'ForegroundTask');
    } catch (e) {
      LoggerService().error('Failed to stop service', tag: 'ForegroundTask', error: e);
    }
  }
}

// Top-level callback required by flutter_foreground_task.
// We don't need to run any Dart code in the service isolate — the sole
// purpose of the foreground service is to keep the process alive.
@pragma('vm:entry-point')
void _foregroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_NoOpTaskHandler());
}

class _NoOpTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}
