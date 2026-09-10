/// Feature flags for gradual EventBus rollout.
class EventBusFeatureFlags {
  EventBusFeatureFlags._();

  /// P2: emit `chat.group.*` projection inside
  /// [GroupEventPerceptionScheduler.schedule].
  static bool groupProjectionEnabled = true;
}
