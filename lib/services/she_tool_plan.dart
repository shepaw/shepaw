/// 惜宝开口前的工具顺序。规则与 Hub `plan_tool_sequence` 相同。
List<String> planSheToolSequence(String user, {String mode = 'dm'}) {
  final text = user.trim().toLowerCase();
  if (mode == 'group') {
    if (_containsAny(text, const ['派给', '发给群', 'group send', '让群里'])) {
      return const ['chat.group.send'];
    }
    return const [];
  }
  if (_containsAny(text, const ['让', '交给', 'dispatch', '跑测试', '帮我让'])) {
    return const ['context.agents.list', 'context.agents.dispatch'];
  }
  if (_containsAny(text, const ['记住', 'remember', '别忘了'])) {
    return const ['context.memory.append'];
  }
  if (_containsAny(text, const ['我叫', 'my name is', '我是', '我在', '住在', 'i live'])) {
    return const ['context.profile.write'];
  }
  return const [];
}

bool _containsAny(String text, List<String> needles) {
  for (final needle in needles) {
    if (text.contains(needle)) return true;
  }
  return false;
}
