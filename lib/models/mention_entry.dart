class MentionEntry {
  final String id;
  final String name;
  final bool notify;

  /// 可选：提及原因，结构化声明时随声明携带，转发给被提及的成员。
  final String? reason;

  const MentionEntry({
    required this.id,
    required this.name,
    required this.notify,
    this.reason,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'notify': notify,
        if (reason != null && reason!.isNotEmpty) 'reason': reason,
      };

  factory MentionEntry.fromJson(Map<String, dynamic> j) => MentionEntry(
        id: j['id'] as String,
        name: j['name'] as String,
        // Tolerate legacy stringified bools — never throw on persisted data.
        notify: j['notify'] is bool ? j['notify'] as bool : true,
        reason: j['reason'] is String ? j['reason'] as String : null,
      );
}
