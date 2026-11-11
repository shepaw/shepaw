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

  test('工作流三层单独成组，按 模板 → 实例 → 运行 排序并可缩进', () {
    const flowId = 'flow:fl_1';
    const instanceId = '$flowId:instance:in_1';
    const runId = '$instanceId:run:run_1';
    for (final id in [flowId, instanceId, runId, 'run:old_run']) {
      expect(PouchScope.parse(id).family, PouchScopeFamily.flow, reason: id);
    }
    expect(PouchScope.parse(flowId).flowDepth, 0);
    expect(PouchScope.parse(instanceId).flowDepth, 1);
    expect(PouchScope.parse(runId).flowDepth, 2);
    expect(PouchScope.parse('run:old_run').flowDepth, 0);

    final groups = groupPouchScopes([
      ...PouchScope.fixed,
      PouchScope.parse(runId),
      PouchScope.parse(instanceId),
      PouchScope.parse(flowId),
    ]);
    expect(groups.map((g) => g.family).toList(), [
      PouchScopeFamily.fixed,
      PouchScopeFamily.flow,
    ]);
    expect(groups.last.label, '工作流');
    expect(groups.last.subtitle, contains('实例'));
    expect(groups.last.scopes.map((s) => s.id).toList(), [
      flowId,
      instanceId,
      runId,
    ]);
  });

  test('scope 解析不 trim，三层树也不接受超过 128 字节的 id', () {
    for (final text in [
      ' flow:f1',
      'flow:f1 ',
      ' agent:a1 ',
      'pouch ',
      // id 形状都合规，唯一的拒绝理由是超过 128 字节。
      'flow:fl_${'a' * 128}:instance:in_1',
      'flow:fl_1:instance:in_1:run:run_${'a' * 110}',
    ]) {
      expect(PouchScope.tryParse(text), isNull, reason: text);
      expect(() => PouchScope.parse(text), throwsFormatException, reason: text);
    }
    // 最长的合法三层 run scope（110 字节）仍要能解析。
    final legal =
        'flow:fl_${'a' * 32}:instance:in_${'a' * 16}:run:run_${'a' * 32}';
    expect(legal.length, 110);
    expect(PouchScope.tryParse(legal), isNotNull);
    // 老的群任务 scope 有 151 字节，靠短前缀列举，必须继续可用。
    final groupTask =
        'group:group_${'a' * 40}:session:s_${'a' * 40}:task:t_${'a' * 40}';
    expect(groupTask.length, greaterThan(128));
    expect(PouchScope.tryParse(groupTask), isNotNull);
  });

  const fid = 'fl_0123456789abcdef0123456789abcdef';
  const iid = 'in_0123456789abcdef';
  const rid = 'run_0123456789abcdef0123456789abcdef';

  test('三层工作流 scope：id / kind / ownerId / parentId', () {
    const flowId = 'flow:$fid';
    const instanceId = '$flowId:instance:$iid';
    const runId = '$instanceId:run:$rid';
    for (final form in [flowId, instanceId, runId]) {
      final scope = PouchScope.parse(form);
      expect(scope.id, form, reason: form);
      expect(scope.format(), form, reason: form);
      expect(PouchScope.tryParse(form), isNotNull, reason: form);
    }

    final flow = PouchScope.parse(flowId);
    expect(flow.kind, PouchScopeKind.flow);
    expect(flow.ownerId, fid);
    expect(flow.parentId, isNull);

    final instance = PouchScope.parse(instanceId);
    expect(instance.kind, PouchScopeKind.instance);
    expect(instance.ownerId, iid);
    expect(instance.parentId, flowId);
    expect(instance.parent?.id, flowId);

    final run = PouchScope.parse(runId);
    expect(run.kind, PouchScopeKind.run);
    expect(run.ownerId, rid);
    expect(run.parentId, instanceId);
    expect(run.parent?.parentId, flowId);
  });

  test('旧两段式 flow / run scope 继续解析，id 形状不写死', () {
    const cases = <String, (PouchScopeKind, String, String?)>{
      'flow:weekly-report': (PouchScopeKind.flow, 'weekly-report', null),
      'flow:My.Flow-1': (PouchScopeKind.flow, 'My.Flow-1', null),
      'run:$rid': (PouchScopeKind.run, rid, null),
      'run:old_run': (PouchScopeKind.run, 'old_run', null),
      'flow:f1': (PouchScopeKind.flow, 'f1', null),
      // 旧两段式别名不挡层级标记（hub 的 parse_flow / parse_legacy_run 同理）。
      'flow:run': (PouchScopeKind.flow, 'run', null),
      'flow:instance': (PouchScopeKind.flow, 'instance', null),
      'run:run': (PouchScopeKind.run, 'run', null),
      'run:instance': (PouchScopeKind.run, 'instance', null),
    };
    for (final entry in cases.entries) {
      final scope = PouchScope.parse(entry.key);
      final (kind, owner, parent) = entry.value;
      expect(scope.id, entry.key, reason: entry.key);
      expect(scope.kind, kind, reason: entry.key);
      expect(scope.ownerId, owner, reason: entry.key);
      expect(scope.parentId, parent, reason: entry.key);
    }
  });

  test('三层 scope 的 id 只认 fl_/in_/run_ + 小写 hex', () {
    // 短 id 与生产的 32/16/32 位 id 都合法：解析器只卡前缀 + 字符集。
    for (final form in [
      'flow:fl_1:instance:in_1',
      'flow:fl_1:instance:in_1:run:run_1',
      'flow:$fid:instance:$iid',
      'flow:$fid:instance:$iid:run:$rid',
      'flow:fl_abc123:instance:in_0f:run:run_deadbeef',
    ]) {
      expect(PouchScope.tryParse(form), isNotNull, reason: form);
      expect(PouchScope.parse(form).id, form, reason: form);
    }
    // 大写 hex、错前缀、非 hex、缺 hex 都拒绝；两段式别名不受影响。
    for (final text in [
      'flow:f1:instance:i1',
      'flow:f1:instance:i1:run:r1',
      'flow:f1:instance:in_1',
      'flow:fl_ABC:instance:in_1',
      'flow:fl_g1:instance:in_1',
      'flow:fl_1:instance:i1',
      'flow:fl_1:instance:in_A',
      'flow:fl_1:instance:in_zz',
      'flow:fl_1:instance:in_1:run:r1',
      'flow:fl_1:instance:in_1:run:RUN_1',
      'flow:fl_1:instance:in_1:run:run_G',
      'flow:fl_1:instance:in_1:run:fl_1',
      'flow:fl_:instance:in_1',
      'flow:fl_1:instance:in_:run:run_1',
      'flow:fl_1:instance:in_1:run:run_',
      'flow:in_1:instance:in_1',
      'flow:fl_1:instance:fl_1',
      'flow:fl_1:instance:in_1:run:in_1',
    ]) {
      expect(PouchScope.tryParse(text), isNull, reason: text);
      expect(() => PouchScope.parse(text), throwsFormatException, reason: text);
    }
  });

  test('工作流 scope 的畸形形状一律拒绝，parse 抛 bad_scope', () {
    for (final text in [
      // 缺 id。
      'flow',
      'flow:',
      'flow:fl_1:',
      'flow:fl_1:instance',
      'flow:fl_1:instance:',
      'flow:fl_1:instance:in_1:run',
      'flow:fl_1:instance:in_1:run:',
      'run',
      'run:',
      // 第 3 / 5 段不是保留关键字。
      'flow:fl_1:foo:in_1',
      'flow:fl_1:instance:in_1:foo:run_1',
      'flow:fl_1:instance:in_1:shared:run_1',
      'flow:fl_1:session:in_1',
      'flow:fl_1:instance:in_1:task:run_1',
      'flow:fl_1:run:run_1',
      'flow:fl_1:instance:in_1:instance:in_2',
      'flow:fl_1:shared',
      'flow:fl_1:run',
      // 层级标记不能占三层形态的 id 位置。
      'flow:run:instance:in_1',
      'flow:instance:instance:in_1',
      'flow:fl_1:instance:run:run_1',
      'flow:fl_1:instance:instance:run:run_1',
      'flow:fl_1:instance:in_1:run:run',
      'flow:fl_1:instance:in_1:run:instance',
      // 拖了多余的段。
      'flow:fl_1:extra',
      'flow:fl_1:instance:in_1:extra',
      'flow:fl_1:instance:in_1:run:run_1:extra',
      'run:r1:extra',
      // id 里带 ':'、'/' 或出现空段。
      'flow:f:1',
      'flow:f:1:instance:in_1',
      'flow:fl_1:instance:i:1',
      'flow:fl_1:instance:in_1:run:r:1',
      'flow:f/1',
      'flow:fl_1:instance:i/1',
      'flow:fl_1:instance:in_1:run:r/1',
      'run:r/1',
      'flow::instance:in_1',
      'flow:fl_1::in_1',
      'flow:fl_1:instance::run:run_1',
      'flow:fl_1:instance:in_1::run_1',
      'flow:fl_1:instance:in_1:run:run 1',
      // 三段以上的 id 不按生成约定拼（两段式别名不受限）。
      'flow:f1:instance:i1',
      'flow:f1:instance:i1:run:r1',
      'flow:fl_ABC:instance:in_1',
      'flow:fl_g1:instance:in_1',
    ]) {
      expect(PouchScope.tryParse(text), isNull, reason: text);
      expect(
        () => PouchScope.parse(text),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('bad_scope'),
          ),
        ),
        reason: text,
      );
    }
  });

  test('工作流构造函数与解析结果一致，非法 id 抛 bad_scope', () {
    expect(PouchScope.flow('fl_1').id, 'flow:fl_1');
    expect(PouchScope.flowInstance('fl_1', 'in_1').parentId, 'flow:fl_1');
    expect(
      PouchScope.flowRun('fl_1', 'in_1', 'run_1').parentId,
      'flow:fl_1:instance:in_1',
    );
    // 生产长度的 id 可以构造，且与解析结果完全一致。
    final realInstance = PouchScope.flowInstance(fid, iid);
    final realRun = PouchScope.flowRun(fid, iid, rid);
    expect(realInstance.id, 'flow:$fid:instance:$iid');
    expect(realRun.id, 'flow:$fid:instance:$iid:run:$rid');
    expect(PouchScope.parse(realInstance.id), realInstance);
    expect(PouchScope.parse(realRun.id), realRun);
    // 构造函数和解析出来的 kind / owner / parent 必须完全一致。
    for (final built in [
      PouchScope.flow('fl_1'),
      PouchScope.flowInstance('fl_1', 'in_1'),
      PouchScope.flowRun('fl_1', 'in_1', 'run_1'),
      realInstance,
      realRun,
      PouchScope.legacyRun('run_1'),
    ]) {
      final parsed = PouchScope.parse(built.id);
      expect(parsed, built, reason: built.id);
      expect(parsed.kind, built.kind, reason: built.id);
      expect(parsed.ownerId, built.ownerId, reason: built.id);
      expect(parsed.parentId, built.parentId, reason: built.id);
    }
    expect(PouchScope.legacyRun('run_1').kind, PouchScopeKind.run);
    expect(PouchScope.legacyRun('run_1').parentId, isNull);
    expect(
      () => PouchScope.flowRun('fl_1', 'in_1', 'a/b'),
      throwsFormatException,
    );
    expect(() => PouchScope.flowInstance('', 'in_1'), throwsFormatException);
    expect(() => PouchScope.flowInstance('run', 'in_1'), throwsFormatException);
    expect(
      () => PouchScope.flowRun('fl_1', 'in_1', 'run'),
      throwsFormatException,
    );
    // 三层构造函数的三个 id 都要按 fl_/in_/run_ + 小写 hex 校验。
    for (final ids in [
      ['f1', iid, rid],
      ['fl_ABC', iid, rid],
      ['fl_g1', iid, rid],
      ['fl_', iid, rid],
      [fid, 'i1', rid],
      [fid, 'in_G1', rid],
      [fid, 'in_', rid],
      [fid, iid, 'r1'],
      [fid, iid, 'RUN_1'],
      [fid, iid, 'run_'],
      [fid, iid, 'fl_1'],
    ]) {
      expect(
        () => PouchScope.flowRun(ids[0], ids[1], ids[2]),
        throwsFormatException,
        reason: ids.join(':'),
      );
    }
    expect(
      () => PouchScope.flowInstance('f1', iid),
      throwsFormatException,
    );
    expect(
      () => PouchScope.flowInstance(fid, 'i1'),
      throwsFormatException,
    );
    // 两段式 flow / legacyRun 仍然宽松。
    expect(PouchScope.flow('weekly-report').id, 'flow:weekly-report');
    expect(PouchScope.legacyRun('old_run').id, 'run:old_run');
    expect(PouchScope.flow('run').kind, PouchScopeKind.flow);
    expect(PouchScope.legacyRun('run').kind, PouchScopeKind.run);
  });
}
