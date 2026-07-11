import '../models/mention_entry.dart';

/// Pure helpers for resolving which group agents a user message should notify.
class GroupMentionResolver {
  GroupMentionResolver._();

  /// Prefer structured [mentions]; fall back to `@name` / `@all` text parsing.
  static List<String> resolveAgentIds({
    required String content,
    required List<MentionEntry> mentions,
    required List<({String id, String name})> agents,
  }) {
    if (mentions.isNotEmpty) {
      final notifyMentions = mentions.where((m) => m.notify).toList();
      if (notifyMentions.any((m) => m.id == 'all')) {
        return agents.map((a) => a.id).toList();
      }
      return notifyMentions.map((m) => m.id).toList();
    }
    return parseFromContent(content, agents);
  }

  /// Legacy text parser used when no structured mentions are provided.
  static List<String> parseFromContent(
    String content,
    List<({String id, String name})> agents,
  ) {
    if (content.contains('@all')) {
      return agents.map((a) => a.id).toList();
    }
    final mentioned = <String>[];
    for (final agent in agents) {
      if (content.contains('@${agent.name}')) {
        mentioned.add(agent.id);
      }
    }
    return mentioned;
  }
}
