import 'dart:async';
import 'package:flutter/widgets.dart';

/// Global singleton that observes the app lifecycle and tracks which
/// chat channel the user is currently viewing.
class AppLifecycleService with WidgetsBindingObserver {
  static final AppLifecycleService _instance = AppLifecycleService._internal();
  factory AppLifecycleService() => _instance;
  AppLifecycleService._internal();

  bool _observing = false;

  /// Whether the app is currently in the foreground.
  bool isInForeground = true;

  /// The channel ID the user is currently viewing, or null.
  String? activeChannelId;

  /// Timestamp (milliseconds since epoch) when the app entered background.
  int? _backgroundedAtMs;

  /// Broadcasts resume events with the duration spent in background.
  final StreamController<Duration> _onResumeController =
      StreamController<Duration>.broadcast();

  /// Stream that fires when the app resumes from background,
  /// carrying the duration it was backgrounded.
  Stream<Duration> get onResume => _onResumeController.stream;

  /// Start observing the app lifecycle. Safe to call multiple times.
  void init() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
  }

  /// Set the active channel (call from ChatScreen).
  void setActiveChannel(String? channelId) {
    activeChannelId = channelId;
  }

  /// Returns true when the notification should be suppressed:
  /// the app is in the foreground AND the user is viewing this exact channel.
  bool shouldSuppressNotification(String channelId) {
    return isInForeground && activeChannelId == channelId;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    isInForeground = state == AppLifecycleState.resumed;

    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // Record when the app entered background (only on the first transition).
      _backgroundedAtMs ??= DateTime.now().millisecondsSinceEpoch;
    } else if (state == AppLifecycleState.resumed && _backgroundedAtMs != null) {
      final duration = Duration(
        milliseconds: DateTime.now().millisecondsSinceEpoch - _backgroundedAtMs!,
      );
      _backgroundedAtMs = null;
      _onResumeController.add(duration);
    }
  }

  void dispose() {
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    _onResumeController.close();
  }
}
