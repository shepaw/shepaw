/// M1 同步表注册表：哪些表进入主从同步、行的身份键、updated_at 归一化。
///
/// 权威协议见 docs/sync_protocol_spec.md §3。agent_memories（每 agent 独立库、
/// 无 uuid 键）不在 M1 范围内，后续里程碑单独设计归并键。
library;

/// 一条同步表描述。
class SyncTable {
  const SyncTable({
    required this.name,
    required this.keyColumns,
    required this.updatedAtKind,
    this.updatedAtColumn = 'updated_at',
    this.fallbackTimeColumn,
    this.transferOmitColumns = const <String>[],
  });

  /// 表名。
  final String name;

  /// 行身份键列（跨设备稳定）。单 uuid 表为 ['id']；
  /// channel_members 为 ['channel_id', 'agent_id']。
  final List<String> keyColumns;

  /// updated_at 列的存储格式。
  final SyncTimeKind updatedAtKind;

  /// updated_at 列名。
  final String updatedAtColumn;

  /// updated_at 为 0/空时的回退时间列（如 messages.created_at）。
  final String? fallbackTimeColumn;

  /// 帧传输与副本落库时排除的列（本地自增主键等跨设备无意义列）。
  final List<String> transferOmitColumns;

  /// 身份键值编码为 tombstone/帧中的单行字符串（uuid 不含 '|'）。
  String keyOf(Map<String, Object?> row) =>
      keyColumns.map((c) => '${row[c]}').join('|');

  /// 把行里的时间列归一化为 INTEGER 毫秒（adopt 冲突比较、帧传输用）。
  int updatedAtMsOf(Map<String, Object?> row) {
    final raw = row[updatedAtColumn];
    final ms = switch (updatedAtKind) {
      SyncTimeKind.integerMs => (raw is int) ? raw : 0,
      SyncTimeKind.isoText =>
        raw is String ? DateTime.tryParse(raw)?.millisecondsSinceEpoch ?? 0 : 0,
    };
    if (ms > 0) return ms;
    final fallback = fallbackTimeColumn;
    if (fallback == null) return 0;
    final fb = row[fallback];
    if (fb is int) return fb;
    if (fb is String) {
      return DateTime.tryParse(fb)?.millisecondsSinceEpoch ?? 0;
    }
    return 0;
  }
}

enum SyncTimeKind { integerMs, isoText }

/// M1 同步表清单（spec §3）。顺序即 adopt/snapshot 的导入顺序
/// （agents 先于 channels/messages，保证副本侧外键语义可读）。
const List<SyncTable> kSyncTables = <SyncTable>[
  SyncTable(
    name: 'agents',
    keyColumns: <String>['id'],
    updatedAtKind: SyncTimeKind.integerMs,
  ),
  SyncTable(
    name: 'channels',
    keyColumns: <String>['id'],
    updatedAtKind: SyncTimeKind.isoText,
  ),
  SyncTable(
    name: 'channel_members',
    keyColumns: <String>['channel_id', 'agent_id'],
    updatedAtKind: SyncTimeKind.integerMs,
    fallbackTimeColumn: 'joined_at',
    // id 为本地自增主键，跨设备无意义；身份键是 (channel_id, agent_id)。
    transferOmitColumns: <String>['id'],
  ),
  SyncTable(
    name: 'messages',
    keyColumns: <String>['id'],
    updatedAtKind: SyncTimeKind.integerMs,
    fallbackTimeColumn: 'created_at',
  ),
  SyncTable(
    name: 'resources',
    keyColumns: <String>['id'],
    updatedAtKind: SyncTimeKind.integerMs,
    fallbackTimeColumn: 'created_at',
  ),
];

SyncTable syncTableByName(String name) =>
    kSyncTables.firstWhere((t) => t.name == name);
