import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/pouch_scope.dart';

void main() {
  test('hub table 里的每个形态都能原样往返', () {
    const forms = [
      'pouch',
      'system',
      'public',
      'files',
      'group:g1',
      'group:g1:shared',
      'group:g1:session:s1',
      'group:g1:session:s1:task:t1',
      'group:g1:member:a1',
      'agent:a1',
      'agent:a1:session:s1',
      'skill:commit-helper',
      'instruction:review',
      'slip:sl_1',
    ];
    for (final form in forms) {
      final scope = PouchScope.parse(form);
      expect(scope.id, form);
      expect(scope.format(), form);
    }
  });

  test('kind / owner / parent 与 hub 的表一致', () {
    const cases = <String, (PouchScopeKind, String, String?)>{
      'pouch': (PouchScopeKind.pouch, '', null),
      'system': (PouchScopeKind.system, '', null),
      'public': (PouchScopeKind.public, '', null),
      'files': (PouchScopeKind.files, '', null),
      'group:g1': (PouchScopeKind.group, 'g1', null),
      'group:g1:shared': (PouchScopeKind.shared, 'g1', 'group:g1'),
      'group:g1:session:s1': (
        PouchScopeKind.session,
        's1',
        'group:g1',
      ),
      'group:g1:session:s1:task:t1': (
        PouchScopeKind.task,
        't1',
        'group:g1:session:s1',
      ),
      'group:g1:member:a1': (PouchScopeKind.member, 'a1', 'group:g1'),
      'agent:a1': (PouchScopeKind.agent, 'a1', null),
      'agent:a1:session:s1': (PouchScopeKind.session, 's1', 'agent:a1'),
      'skill:commit-helper': (PouchScopeKind.skill, 'commit-helper', null),
      'instruction:review': (PouchScopeKind.instruction, 'review', null),
      'slip:sl_1': (PouchScopeKind.slip, 'sl_1', null),
    };
    for (final entry in cases.entries) {
      final scope = PouchScope.parse(entry.key);
      final (kind, owner, parent) = entry.value;
      expect(scope.kind, kind, reason: entry.key);
      expect(scope.ownerId, owner, reason: entry.key);
      expect(scope.parentId, parent, reason: entry.key);
    }
  });

  test('关键字不能当 id', () {
    for (final text in [
      'agent:session',
      'agent:shared',
      'agent:task',
      'agent:member',
      'skill:session',
      'slip:shared',
      'group:session',
    ]) {
      expect(PouchScope.tryParse(text), isNull, reason: text);
      expect(() => PouchScope.parse(text), throwsFormatException, reason: text);
    }
  });

  test('表外的形态与非法 id 都拒绝', () {
    for (final text in [
      '',
      ':',
      'foo:bar',
      'Group:g1',
      'pouch:x',
      'files/',
      'group:',
      'group:g1:',
      'group:g1:shared:x',
      'group:g1:member',
      'group:g1:session',
      'group:g1:session:s1:member:a1',
      'group:g1:session:s1:task:t1:extra',
      'agent:a1:session',
      'agent:a1:session:s1:task:t1',
      'skill:',
      'slip:a:b',
      'group:g 1',
      'group:g/1',
      'group:g:1',
      'agent:a1:session:s 1',
      'slip:a%b',
    ]) {
      expect(PouchScope.tryParse(text), isNull, reason: text);
    }
  });

  test('构造函数拒绝非法 id', () {
    expect(() => PouchScope.group(''), throwsFormatException);
    expect(() => PouchScope.group('g 1'), throwsFormatException);
    expect(() => PouchScope.agent('session'), throwsFormatException);
    expect(() => PouchScope.slip('a/b'), throwsFormatException);
    expect(PouchScope.groupSession('g1', 's1').id, 'group:g1:session:s1');
    expect(
      PouchScope.groupTask('g1', 's1', 't1').id,
      'group:g1:session:s1:task:t1',
    );
    expect(PouchScope.agentSession('a1', 's1').parentId, 'agent:a1');
  });

  test('展示名带 kind 和归属 id', () {
    expect(PouchScope.files.displayName, '文件');
    expect(PouchScope.pouch.displayName, '袋子');
    expect(PouchScope.parse('group:g1').displayName, '群 g1');
    expect(PouchScope.parse('group:g1:shared').displayName, '群 g1 · 共享');
    expect(PouchScope.parse('agent:a1:session:s1').displayName, '会话 s1');
    expect(PouchScope.parse('slip:sl_1').displayName, '玉简 sl_1');
  });

  test('会话/任务跟着父 scope 归家族', () {
    expect(
      PouchScope.parse('agent:a1:session:s1').family,
      PouchScopeFamily.agent,
    );
    expect(
      PouchScope.parse('group:g1:session:s1:task:t1').family,
      PouchScopeFamily.group,
    );
  });

  test('分组：固定分区在前，家族内按 id 排序', () {
    final groups = groupPouchScopes([
      PouchScope.parse('slip:sl_2'),
      PouchScope.parse('agent:a2'),
      PouchScope.parse('agent:a1'),
      ...PouchScope.fixed,
      PouchScope.parse('group:g2'),
      PouchScope.parse('group:g1'),
    ]);
    expect(groups.map((g) => g.family).toList(), [
      PouchScopeFamily.fixed,
      PouchScopeFamily.group,
      PouchScopeFamily.agent,
      PouchScopeFamily.slip,
    ]);
    expect(groups.first.scopes.map((s) => s.id).toList(), [
      'pouch',
      'system',
      'public',
      'files',
    ]);
    expect(
        groups[2].scopes.map((s) => s.id).toList(), ['agent:a1', 'agent:a2']);
  });
}
