class MentionEntry {
  final String id;
  final String name;
  final bool notify;

  const MentionEntry({
    required this.id,
    required this.name,
    required this.notify,
  });

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'notify': notify};

  factory MentionEntry.fromJson(Map<String, dynamic> j) => MentionEntry(
        id: j['id'] as String,
        name: j['name'] as String,
        notify: j['notify'] as bool? ?? true,
      );
}
