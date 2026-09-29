import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/app_paths.dart';
import 'store_protocol.dart';

/// 应用数据在储物袋里的位置：`store://app/shepaw/...`。
///
/// 磁盘是 `<store>/shepaw/app/<path>`。SQLite 可以直接打开这个文件。
/// 不引用 [StoreService]，避免和主库服务绕成循环依赖。
class PouchSqlite {
  PouchSqlite._();

  static const mainDb = 'shepaw.db';
  static const toolResultsDb = 'tool_results.db';
  static const sqliteDir = 'sqlite';

  static String uri(String rel) =>
      'store://${StoreSpace.app}/${StoreSpace.appDevice}/$rel';

  static String dbUri(String name) => uri('$sqliteDir/$name');

  static Future<Directory> sqliteDirectory() async {
    final marker = await file('$sqliteDir/shepaw.db');
    return marker.parent;
  }

  static Future<File> file(String rel) async {
    final docs = await AppPaths.documents();
    final dir = Directory(p.join(
      docs.path,
      'shepaw',
      'store',
      StoreSpace.appDevice,
      StoreSpace.app,
    ));
    final target = File(p.join(dir.path, rel));
    if (!target.parent.existsSync()) {
      target.parent.createSync(recursive: true);
    }
    return target;
  }

  /// 打开用的路径。没有旧库可搬，文件不存在就等 SQLite 自己建。
  static Future<String> openPath(String name) async {
    final target = await file('$sqliteDir/$name');
    return target.path;
  }

  static Future<void> delete(String name) async {
    final target = await file('$sqliteDir/$name');
    await _deleteSet(target.path);
  }

  /// 删掉 `sqlite/` 里指定前缀的库。
  static Future<void> deletePrefixed(String prefix) async {
    final dir = await sqliteDirectory();
    if (!dir.existsSync()) return;
    final names = <String>[];
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith(prefix) && name.endsWith('.db')) names.add(name);
    }
    for (final name in names) {
      await delete(name);
    }
  }

  static Future<void> _deleteSet(String path) async {
    for (final suffix in const ['', '-wal', '-shm', '.pre-restore']) {
      final file = File('$path$suffix');
      if (file.existsSync()) await file.delete();
    }
  }
}
