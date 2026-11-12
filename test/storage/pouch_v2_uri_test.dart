import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/store_protocol.dart';

void main() {
  test('a v2 uri splits into pouch id, scope and path', () {
    final uri = PouchV2Uri.tryParse(
      'pouch://a95b5782-4d50-45d2-83e1-8e40954d1239/agent:a1:session:s_1/files/x.md',
    );
    expect(uri, isNotNull);
    expect(uri!.pouchId, 'a95b5782-4d50-45d2-83e1-8e40954d1239');
    expect(uri.scope, 'agent:a1:session:s_1');
    expect(uri.path, 'files/x.md');
    expect(uri.hasPath, isTrue);
    expect(uri.format(), contains('/agent:a1:session:s_1/files/x.md'));
  });

  test('a scope-only uri has an empty path', () {
    final uri = PouchV2Uri.tryParse('pouch://pouch-a/group:g1:shared');
    expect(uri, isNotNull);
    expect(uri!.scope, 'group:g1:shared');
    expect(uri.hasPath, isFalse);
  });

  test('junk and placeholders are not v2 uris', () {
    expect(PouchV2Uri.tryParse('pouch://pouch-a'), isNull);
    expect(PouchV2Uri.tryParse('file:///tmp/a.md'), isNull);
    expect(PouchV2Uri.tryParse('pouch://<pouch_id>/<scope>/<path>'), isNull);
    expect(PouchV2Uri.tryParse('pouch://pouch a/files/x.md'), isNull);
  });

  test('parseStoreUri refuses to treat a pouch id as a space', () {
    expect(
      () => parseStoreUri(
        'pouch://a95b5782-4d50-45d2-83e1-8e40954d1239/files/x.md',
      ),
      throwsFormatException,
    );
    // 两段式的本机 store 地址照旧。
    expect(parseStoreUri('pouch://files/x.md').space, 'files');
  });

  test('workflow scopes keep their own segment in v2 uris', () {
    const fid = 'fl_0123456789abcdef0123456789abcdef';
    const iid = 'in_0123456789abcdef';
    const rid = 'run_0123456789abcdef0123456789abcdef';
    for (final scope in [
      'flow:$fid',
      'flow:$fid:instance:$iid',
      'flow:$fid:instance:$iid:run:$rid',
      'flow:weekly-report',
      'run:$rid',
    ]) {
      final raw = 'pouch://pouch-a/$scope/files/x.md';
      final uri = PouchV2Uri.tryParse(raw);
      expect(uri, isNotNull, reason: raw);
      expect(uri!.scope, scope, reason: raw);
      expect(uri.path, 'files/x.md', reason: raw);
      expect(uri.format(), contains('/$scope/files/x.md'), reason: raw);
    }

    final legacy = PouchV2Uri.tryParse('pouch://pouch-a/run:old_run');
    expect(legacy, isNotNull);
    expect(legacy!.parsedScope.kind, PouchScopeKind.run);
    expect(legacy.parsedScope.parentId, isNull);
    expect(legacy.hasPath, isFalse);
  });

  test('malformed workflow scopes are not v2 uris', () {
    for (final scope in [
      // 结构畸形：id 都合规，拒绝理由是段数 / 层级标记 / 空段。
      'flow:',
      'run:',
      'flow:fl_1:instance',
      'flow:fl_1:step:in_1',
      'flow:fl_1:instance:in_1:step:run_1',
      'flow:fl_1:instance:in_1:run:run_1:extra',
      'flow:fl_1::in_1',
      'flow:fl_1:instance:in_1::run_1',
      'flow:run:instance:in_1',
      'flow:fl_1:instance:in_1:run:run',
      'run:r1:extra',
      // id 形状违规（三段以上只认 fl_/in_/run_ + 小写 hex）。
      'flow:f:1',
      'flow:fl_1:instance:in_1:run:r:1',
      'flow:f1:instance:i1',
      'flow:f1:instance:i1:run:r1',
      'flow:fl_ABC:instance:in_1',
      'flow:fl_g1:instance:in_1',
      'flow:fl_1:instance:in_1:run:r1',
      'flow:fl_1:instance:in_1:run:run_G',
    ]) {
      final raw = 'pouch://pouch-a/$scope/files/x.md';
      expect(PouchV2Uri.tryParse(raw), isNull, reason: raw);
      expect(() => PouchV2Uri.parse(raw), throwsFormatException, reason: raw);
    }
  });
}
