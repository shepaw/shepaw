/// Tracks app foreground/background for chat resume handling.
class ChatLifecycleCoordinator {
  bool isAppActive = true;
  int? backgroundedAtMs;

  /// Update active flag. Returns true when the app just resumed from background
  /// and callers should schedule [handleResumeFromBackground]-style work.
  bool onLifecycleChanged(bool resumed, {int? nowMs}) {
    final wasActive = isAppActive;
    isAppActive = resumed;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;

    if (!resumed) {
      backgroundedAtMs ??= now;
      return false;
    }

    return !wasActive;
  }

  /// Consume and clear the backgrounded timestamp.
  int? takeBackgroundedAtMs() {
    final value = backgroundedAtMs;
    backgroundedAtMs = null;
    return value;
  }

  /// Duration spent in background, or null when [bgMs] is missing.
  static Duration? backgroundDuration(int? bgMs, {int? nowMs}) {
    if (bgMs == null) return null;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return Duration(milliseconds: now - bgMs);
  }
}
