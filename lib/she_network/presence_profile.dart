import '../models/remote_agent.dart';

/// 类别级 presence 画像（方案 §8.1：不暴露 Agent 名单）。
class PresenceProfile {
  const PresenceProfile({
    required this.agentCategories,
    required this.toolCategories,
    required this.agentCount,
  });

  final List<String> agentCategories;
  final List<String> toolCategories;
  final int agentCount;

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
  for (final a in list) {
    agentCats.add(a.isShe ? 'she' : 'assistant');
    for (final t in a.enabledOsTools) {
      final cat = _normalizeToolCategory(t);
      if (cat != null) toolCats.add(cat);
    }
    for (final c in a.capabilities) {
      final cat = _normalizeToolCategory(c);
      if (cat != null) toolCats.add(cat);
    }
  }
  if (toolCats.isEmpty) {
    // 至少有 Agent 但未声明工具时，不虚构 tool 类别
  }
  final agentSorted = agentCats.toList()..sort();
  final toolSorted = toolCats.toList()..sort();
  return PresenceProfile(
    agentCategories: agentSorted,
    toolCategories: toolSorted,
    agentCount: list.length,
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
