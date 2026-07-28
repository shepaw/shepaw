import '../models/remote_agent.dart';

/// 名单级 Agent 条目（方案 §8.1 升级；需用户开启分享）。
class PresenceAgentEntry {
  const PresenceAgentEntry({
    required this.id,
    required this.name,
    required this.category,
  });

  final String id;
  final String name;

  /// `she` | `assistant`
  final String category;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'category': category,
      };

  static PresenceAgentEntry? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final id = json['id'] as String? ?? '';
    final name = json['name'] as String? ?? '';
    if (id.isEmpty || name.isEmpty) return null;
    return PresenceAgentEntry(
      id: id,
      name: name,
      category: json['category'] as String? ?? 'assistant',
    );
  }
}

/// 类别级 presence 画像（方案 §8.1；可选附带 Agent 名单）。
class PresenceProfile {
  const PresenceProfile({
    required this.agentCategories,
    required this.toolCategories,
    required this.agentCount,
    this.agents = const [],
  });

  final List<String> agentCategories;
  final List<String> toolCategories;
  final int agentCount;
  final List<PresenceAgentEntry> agents;

  /// 无 Agent 时的保守默认（兼容旧广播）。
  static const fallback = PresenceProfile(
    agentCategories: ['she', 'assistant'],
    toolCategories: ['filesystem', 'web', 'shell'],
    agentCount: 1,
  );
}

/// 从本机 Agent 列表聚合类别与数量（纯函数，便于单测）。
PresenceProfile aggregatePresenceProfile(Iterable<RemoteAgent> agents) {
  final list = agents.toList();
  if (list.isEmpty) return PresenceProfile.fallback;

  final agentCats = <String>{};
  final toolCats = <String>{};
  final roster = <PresenceAgentEntry>[];
  for (final a in list) {
    final cat = a.isShe ? 'she' : 'assistant';
    agentCats.add(cat);
    roster.add(PresenceAgentEntry(id: a.id, name: a.name, category: cat));
    for (final t in a.enabledOsTools) {
      final c = _normalizeToolCategory(t);
      if (c != null) toolCats.add(c);
    }
    for (final c in a.capabilities) {
      final cat2 = _normalizeToolCategory(c);
      if (cat2 != null) toolCats.add(cat2);
    }
  }
  final agentSorted = agentCats.toList()..sort();
  final toolSorted = toolCats.toList()..sort();
  return PresenceProfile(
    agentCategories: agentSorted,
    toolCategories: toolSorted,
    agentCount: list.length,
    agents: roster,
  );
}

String? _normalizeToolCategory(String raw) {
  final t = raw.trim().toLowerCase().replaceAll('-', '_');
  if (t.isEmpty) return null;
  switch (t) {
    case 'filesystem':
    case 'fs':
    case 'file':
    case 'files':
      return 'filesystem';
    case 'shell':
    case 'bash':
    case 'terminal':
    case 'cli':
      return 'shell';
    case 'web':
    case 'web_search':
    case 'browser':
    case 'http':
    case 'fetch':
      return 'web';
    default:
      // 已是规范类别名则保留；过长/含空格的原始 capability 不广播
      if (t == 'filesystem' || t == 'shell' || t == 'web') return t;
      if (RegExp(r'^[a-z][a-z0-9_]{1,31}$').hasMatch(t)) return t;
      return null;
  }
}
