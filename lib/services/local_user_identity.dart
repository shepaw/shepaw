/// Local-first identity for the on-device user.
///
/// ShePaw no longer uses HTTP login + WebSocket [AppState]; chat / peer paths
/// historically fell back to these literals when `AppState.currentUser` was
/// always null. Centralize them so UI and services stay consistent.
class LocalUserIdentity {
  LocalUserIdentity._();

  static const String id = 'user';
  static const String displayName = 'User';
}
