import '../../models/mention_entry.dart';
import '../../models/remote_agent.dart';

/// Detects when an admin reply assigns work in natural language (or via
/// display-only `@mention` / `group_mention`) without calling `group_dispatch`.
class GroupVerbalDispatchDetector {
  GroupVerbalDispatchDetector._();

  static final _atAll = RegExp(r'@all\b', caseSensitive: false);
  static final _negation = RegExp(
    r'(不|别|未|没|没有|无需|不用|不要|勿)(再)?\s*(让|请|叫|安排|委派|交给|分配|通知|指派|ask|assign|have|let|tell)?\s*$',
    caseSensitive: false,
  );
  static final _zhPrefixVerb = RegExp(
    r'(让|请|叫|安排|委派|交给|分配|通知|指派)\s*$',
  );
  static final _enPrefixVerb = RegExp(
    r'(?:ask|assign(?:ed)?|have|let|tell)\s+$',
    caseSensitive: false,
  );
  static final _zhSuffixAssign = RegExp(
    r'^\s*(去|来)(做|写|改|查|实现|处理|完成|跑|看|负责)',
  );
  static final _enSuffixAssign = RegExp(
    r'^\s*(will|should|shall)\s+(handle|do|write|implement|take|work)',
    caseSensitive: false,
  );

  /// Member display names that look verbally assigned in [content].
  ///
  /// [members] should already exclude the admin. Empty / `[SKIP]` replies
  /// produce no hits.
  static List<String> promisedNames({
    required String content,
    required List<RemoteAgent> members,
    List<MentionEntry> mentions = const [],
  }) {
    if (members.isEmpty) return const [];
    final text = content.replaceAll('＠', '@').trim();
    if (text.isEmpty || text.contains('[SKIP]')) return const [];

    final found = <String>{};

    for (final m in mentions) {
      if (!m.notify) continue;
      if (m.id == 'all') {
        found.addAll(members.map((a) => a.name));
        continue;
      }
      for (final agent in members) {
        if (agent.id == m.id || agent.name == m.name) {
          found.add(agent.name);
        }
      }
    }

    if (_atAll.hasMatch(text)) {
      found.addAll(members.map((a) => a.name));
    }

    final sorted = [...members]
      ..sort((a, b) => b.name.length.compareTo(a.name.length));
    for (final agent in sorted) {
      if (found.contains(agent.name)) continue;
      if (_isAssigned(text, agent.name)) found.add(agent.name);
    }
    return [
      for (final agent in members)
        if (found.contains(agent.name)) agent.name,
    ];
  }

  static String nudgeSystemContent(List<String> names) {
    final listed = names.join('、');
    return '[SYSTEM] 你刚才在自然语言中提到要委派「$listed」，但没有调用 `group_dispatch`。'
        '系统不会根据口头承诺派活。请立刻调用 `group_dispatch`（agents 必须用注册名），'
        '或调用 `group_finish`（done/continue/pause）并明确改为自己处理或结束。';
  }

  static String exhaustedWarning(List<String> names) {
    return '⚠️ 管理员口头提到委派「${names.join('、')}」但未调用 group_dispatch，本轮未派活。';
  }

  static bool _isAssigned(String text, String name) {
    if (name.isEmpty) return false;
    if (_hasAtMention(text, name)) return true;
    if (name.length < 2) return false;

    final escaped = RegExp.escape(name);
    final latin = RegExp(r'^[\p{L}\p{N}_-]+$', unicode: true).hasMatch(name);
    final token = latin
        ? RegExp(
            '(^|[^\\p{L}\\p{N}_])$escaped(?=\$|[^\\p{L}\\p{N}_])',
            unicode: true,
            caseSensitive: false,
          )
        : RegExp(escaped, caseSensitive: false);

    for (final match in token.allMatches(text)) {
      final start = latin && match.groupCount >= 1
          ? match.start + (match.group(1)?.length ?? 0)
          : match.start;
      if (_isNegated(text, start)) continue;
      final before = text.substring(0, start);
      final after = text.substring(match.end);
      if (_zhPrefixVerb.hasMatch(before) || _enPrefixVerb.hasMatch(before)) {
        return true;
      }
      if (_zhSuffixAssign.hasMatch(after) || _enSuffixAssign.hasMatch(after)) {
        return true;
      }
    }
    return false;
  }

  static bool _hasAtMention(String text, String name) {
    final pattern = RegExp(
      '@${RegExp.escape(name)}(?![\\p{L}\\p{N}·-])',
      unicode: true,
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(text)) {
      if (!_isNegated(text, match.start)) return true;
    }
    return false;
  }

  static bool _isNegated(String text, int start) {
    final from = start > 12 ? start - 12 : 0;
    return _negation.hasMatch(text.substring(from, start));
  }
}
