import '../services/local_database_service.dart';

/// presence 隐私开关：是否向 owner 圈子附带本机 Agent 名单。
class PresenceSettings {
  PresenceSettings({required this.shareRoster});

  final bool shareRoster;

  static const _shareRosterKey = 'she_network.presence.share_roster';

  static Future<PresenceSettings> load() async {
    final db = LocalDatabaseService();
    // 默认关闭：名单分享需显式开启（opt-in）。
    final share = (await db.getUserValue(_shareRosterKey)) == '1';
    return PresenceSettings(shareRoster: share);
  }

  Future<void> save() async {
    final db = LocalDatabaseService();
    await db.setUserValue(_shareRosterKey, shareRoster ? '1' : '0');
  }

  PresenceSettings copyWith({bool? shareRoster}) =>
      PresenceSettings(shareRoster: shareRoster ?? this.shareRoster);
}
