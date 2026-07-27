import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/storage/device_cursor_store.dart';

void main() {
  late Directory tmp;
  late DeviceCursorStore cursors;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('device_cursor_test');
    cursors = DeviceCursorStore(storeRoot: tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('remove 删除游标并持久化', () async {
    await cursors.advance('aaaaaaaaaaaaaaaa', 3);
    await cursors.advance('bbbbbbbbbbbbbbbb', 5);
    await cursors.remove('bbbbbbbbbbbbbbbb');
    expect(await cursors.all(), {'aaaaaaaaaaaaaaaa': 3});

    final reloaded = DeviceCursorStore(storeRoot: tmp);
    expect(await reloaded.all(), {'aaaaaaaaaaaaaaaa': 3});
    expect(File(p.join(tmp.path, '.system', 'device_cursors.json')).existsSync(),
        isTrue);
  });
}
