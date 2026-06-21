/// 本机已保存的账号条目（密钥与数据按 accountId 隔离）。
class LocalAccountEntry {
  final String accountId;
  final String displayName;
  final int createdAtMs;
  final int lastUsedAtMs;

  const LocalAccountEntry({
    required this.accountId,
    this.displayName = '',
    required this.createdAtMs,
    required this.lastUsedAtMs,
  });

  String get label {
    if (displayName.isNotEmpty) return displayName;
    if (accountId.length <= 8) return accountId;
    return '••••${accountId.substring(accountId.length - 8)}';
  }

  Map<String, dynamic> toJson() => {
        'account_id': accountId,
        'display_name': displayName,
        'created_at_ms': createdAtMs,
        'last_used_at_ms': lastUsedAtMs,
      };

  factory LocalAccountEntry.fromJson(Map<String, dynamic> json) {
    return LocalAccountEntry(
      accountId: json['account_id'] as String,
      displayName: json['display_name'] as String? ?? '',
      createdAtMs: json['created_at_ms'] as int,
      lastUsedAtMs: json['last_used_at_ms'] as int? ?? json['created_at_ms'] as int,
    );
  }

  LocalAccountEntry copyWith({
    String? displayName,
    int? lastUsedAtMs,
  }) {
    return LocalAccountEntry(
      accountId: accountId,
      displayName: displayName ?? this.displayName,
      createdAtMs: createdAtMs,
      lastUsedAtMs: lastUsedAtMs ?? this.lastUsedAtMs,
    );
  }
}
