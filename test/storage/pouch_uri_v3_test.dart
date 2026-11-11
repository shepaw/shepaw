import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/store_protocol.dart';

const _pouch = 'a95b5782-4d50-45d2-83e1-8e40954d1239';

void main() {
  test('路径里的空格、#、%、中文、emoji 都能往返', () {
    for (final path in [
      'docs/a.md',
      'docs/中文 备忘.md',
      'a%b.md',
      'weird#name?x=1&y',
      'deep/nested/目录/file name.txt',
      'emoji-😀.txt',
    ]) {
      final uri = PouchV2Uri(pouchId: _pouch, scope: 'files', path: path);
      final parsed = PouchV2Uri.parse(uri.format());
      expect(parsed.pouchId, _pouch);
      expect(parsed.scope, 'files');
      expect(parsed.path, path, reason: uri.format());
    }
  });

  test('编码用大写 %XX，未保留字符照抄', () {
    const uri = PouchV2Uri(
      pouchId: _pouch,
      scope: 'files',
      path: 'a b/中文~x.md',
    );
    expect(
      uri.format(),
      'pouch://$_pouch/files/a%20b/%E4%B8%AD%E6%96%87~x.md',
    );
    expect(uri.format(), isNot(contains('%e4')));
  });

  test('带冒号的 scope 保持可读', () {
    const uri = PouchV2Uri(
      pouchId: _pouch,
      scope: 'group:g1:session:s1',
      path: 'logs/chat',
    );
    expect(uri.format(), 'pouch://$_pouch/group:g1:session:s1/logs/chat');
    expect(
        PouchV2Uri.parse(uri.format()).parsedScope.id, 'group:g1:session:s1');
  });

  test('没有路径的地址也能往返', () {
    const uri = PouchV2Uri(pouchId: _pouch, scope: 'pouch', path: '');
    expect(uri.format(), 'pouch://$_pouch/pouch');
    expect(PouchV2Uri.parse(uri.format()).path, '');
    expect(PouchV2Uri.parse('pouch://$_pouch/pouch/').path, '');
  });

  test('旧的两段式地址不是 v3 地址', () {
    for (final raw in [
      'pouch://files/a',
      'pouch://files',
      'pouch://pouch/read_state/x.json',
    ]) {
      expect(PouchV2Uri.tryParse(raw), isNull, reason: raw);
      expect(() => PouchV2Uri.parse(raw), throwsFormatException, reason: raw);
    }
  });

  test('非法 scope / 袋子 id 拒绝', () {
    expect(
      () => PouchV2Uri.parse('pouch://$_pouch/nope/a.md'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('bad_scope'),
        ),
      ),
    );
    expect(PouchV2Uri.tryParse('pouch://pouch a/files/x.md'), isNull);
    expect(
      () => PouchV2Uri.parse('pouch://$_pouch/agent:session/x.md'),
      throwsFormatException,
    );
    expect(
      () => PouchV2Uri.parse('pouch://$_pouch/files/%ZZ.md'),
      throwsFormatException,
    );
    expect(
      () => PouchV2Uri.parse('pouch://$_pouch/files/%E4.md'),
      throwsFormatException,
    );
  });

  test('袋子 id 与 scope 的 id 用同一套字符集', () {
    expect(isValidPouchScopeId('a95b5782-4d50-45d2-83e1-8e40954d1239'), isTrue);
    expect(isValidPouchScopeId('pouch-a'), isTrue);
    expect(isValidPouchScopeId(''), isFalse);
    expect(isValidPouchScopeId('a b'), isFalse);
    expect(isValidPouchScopeId('session'), isFalse);
    expect(isValidPouchScopeId('a/b'), isFalse);
    expect(PouchScope.tryParse('group:g1'), isNotNull);
  });

  test('工作流三层与旧两段式 scope 在 v3 地址里原样往返', () {
    const fid = 'fl_0123456789abcdef0123456789abcdef';
    const iid = 'in_0123456789abcdef';
    const rid = 'run_0123456789abcdef0123456789abcdef';
    const flowId = 'flow:$fid';
    const instanceId = '$flowId:instance:$iid';
    const runId = '$instanceId:run:$rid';
    for (final scope in [
      flowId,
      instanceId,
      runId,
      'flow:weekly-report',
      'run:$rid',
    ]) {
      final uri = PouchV2Uri(pouchId: _pouch, scope: scope, path: 'files/a.md');
      final parsed = PouchV2Uri.parse(uri.format());
      expect(parsed.scope, scope, reason: uri.format());
      expect(parsed.parsedScope.id, scope, reason: uri.format());
      expect(parsed.path, 'files/a.md', reason: uri.format());
    }
    expect(
      PouchV2Uri.parse('pouch://$_pouch/$runId').parsedScope.parentId,
      instanceId,
    );
    expect(
      PouchV2Uri.parse('pouch://$_pouch/$instanceId').parsedScope.kind,
      PouchScopeKind.instance,
    );
    expect(
      PouchV2Uri.parse('pouch://$_pouch/run:$rid').parsedScope.kind,
      PouchScopeKind.run,
    );
    expect(
      PouchV2Uri.parse('pouch://$_pouch/run:$rid').parsedScope.parentId,
      isNull,
    );
  });

  test('畸形工作流 scope 在 v3 地址里报 bad_scope', () {
    for (final scope in [
      // 结构畸形：id 都合规，拒绝理由是段数 / 层级标记。
      'flow:',
      'run:',
      'flow:fl_1:instance',
      'flow:fl_1:step:in_1',
      'flow:fl_1:instance:in_1:step:run_1',
      'flow:fl_1:instance:in_1:run:run_1:extra',
      'flow:run:instance:in_1',
      'flow:fl_1:instance:in_1:run:run',
      'run:r1:extra',
      // 三段以上的 id 形状违规：大写 hex / 非 hex / 错前缀。
      'flow:f1:instance:i1',
      'flow:f1:instance:i1:run:r1',
      'flow:fl_ABC:instance:in_1',
      'flow:fl_g1:instance:in_1',
      'flow:fl_1:instance:in_1:run:r1',
      'flow:fl_1:instance:in_1:run:run_G',
    ]) {
      final raw = 'pouch://$_pouch/$scope/a.md';
      expect(PouchV2Uri.tryParse(raw), isNull, reason: raw);
      expect(
        () => PouchV2Uri.parse(raw),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('bad_scope'),
          ),
        ),
        reason: raw,
      );
    }
  });
}
