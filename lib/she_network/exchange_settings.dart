import '../services/local_database_service.dart';
import 'she_network_protocol.dart';

/// 记忆交换开关（总开关 + 类别级）。
class ExchangeSettings {
  ExchangeSettings({
    required this.enabled,
    required this.kinds,
  });

  final bool enabled;
  final Set<String> kinds;

  static const _enabledKey = 'she_network.exchange.enabled';
  static const _kindsKey = 'she_network.exchange.kinds';

  static Future<ExchangeSettings> load() async {
    final db = LocalDatabaseService();
    // 默认关闭：记忆交换需用户显式开启（opt-in）。
    final enabled = (await db.getUserValue(_enabledKey)) == '1';
    final raw = await db.getUserValue(_kindsKey);
    final kinds = <String>{};
    if (raw == null || raw.isEmpty) {
      kinds.addAll(DigestKind.all);
    } else {
      for (final k in raw.split(',')) {
        if (DigestKind.isValid(k)) kinds.add(k);
      }
      if (kinds.isEmpty) kinds.addAll(DigestKind.all);
    }
    return ExchangeSettings(enabled: enabled, kinds: kinds);
  }

  Future<void> save() async {
    final db = LocalDatabaseService();
    await db.setUserValue(_enabledKey, enabled ? '1' : '0');
    await db.setUserValue(_kindsKey, kinds.join(','));
  }

  ExchangeSettings copyWith({bool? enabled, Set<String>? kinds}) =>
      ExchangeSettings(
        enabled: enabled ?? this.enabled,
        kinds: kinds ?? Set.of(this.kinds),
      );
}
