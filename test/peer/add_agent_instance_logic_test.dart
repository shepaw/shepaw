import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/add_agent_instance_logic.dart';

void main() {
  test('不可用的引擎排到后面，组内顺序不变', () {
    final sorted = sortEnginesUnavailableLast(
      ['codex', 'claude', 'cursor', 'kimi'],
      (id) => id == 'claude' || id == 'kimi',
    );
    expect(sorted, ['claude', 'kimi', 'codex', 'cursor']);
  });

  test('引擎关键词匹配子串和子序列', () {
    expect(
      matchEngineKeyword(id: 'claude-code', name: 'Claude Code', query: ''),
      isTrue,
    );
    expect(
      matchEngineKeyword(id: 'claude-code', name: 'Claude Code', query: 'code'),
      isTrue,
    );
    expect(
      matchEngineKeyword(id: 'claude-code', name: 'Claude Code', query: 'cc'),
      isTrue,
    );
    expect(
      matchEngineKeyword(id: 'claude-code', name: 'Claude Code', query: 'zzz'),
      isFalse,
    );
  });

  test('目录历史去重并把最新的放在前面，超过 30 条截断', () {
    final deduped = rememberCwd(['/work/1', '/tmp'], '/work/1/');
    expect(deduped, ['/work/1/', '/tmp']);
    final history = [for (var i = 0; i < 30; i++) '/work/$i'];
    final next = rememberCwd(history, '/work/new');
    expect(next.first, '/work/new');
    expect(next.length, 30);
    expect(next.contains('/work/29'), isFalse);
  });

  test('已有实例的目录接在本地历史后面，相同路径不重复', () {
    final merged = mergeCwdSuggestions(
      ['/home/me/app/', '/tmp/other'],
      ['/home/me/app', '/srv/new'],
    );
    expect(merged, ['/home/me/app/', '/tmp/other', '/srv/new']);
  });
}
