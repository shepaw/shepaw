import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/app_paths.dart';
import 'package:shepaw/storage/pouch_sqlite.dart';
import 'package:shepaw/storage/store_protocol.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pouch_sqlite_');
    AppPaths.setRootForTesting(root);
  });

  tearDown(() async {
    AppPaths.setRootForTesting(null);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('库直接开在储物袋里，文稿目录里的同名文件不动', () async {
    final leftover = File('${root.path}/shepaw.db');
    await leftover.writeAsString('leftover');

    final path = await PouchSqlite.openPath(PouchSqlite.mainDb);
    expect(File(path).existsSync(), isFalse);
    expect(leftover.readAsStringSync(), 'leftover');
    expect(
      path,
      endsWith(
        '${Platform.pathSeparator}shepaw${Platform.pathSeparator}app${Platform.pathSeparator}sqlite${Platform.pathSeparator}shepaw.db',
      ),
    );
    expect(
      PouchSqlite.dbUri(PouchSqlite.mainDb),
      'store://app/shepaw/sqlite/shepaw.db',
    );

    await File(path).writeAsString('fresh');
    await PouchSqlite.delete(PouchSqlite.mainDb);
    expect(File(path).existsSync(), isFalse);
    expect(leftover.existsSync(), isTrue);
  });

  test('app 分区接受 shepaw，其它分区不接受', () {
    final parsed = parseStoreUri('store://app/shepaw/sqlite/shepaw.db');
    expect(parsed.space, StoreSpace.app);
    expect(parsed.device, StoreSpace.appDevice);
    expect(parsed.path, 'sqlite/shepaw.db');
    expect(
      () => parseStoreUri('store://files/shepaw/a.txt'),
      throwsFormatException,
    );
  });
}
