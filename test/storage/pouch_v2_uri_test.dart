import 'package:flutter_test/flutter_test.dart';
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
}
