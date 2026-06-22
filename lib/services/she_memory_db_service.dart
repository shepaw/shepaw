import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

/// She 专用记忆数据库（按账号隔离路径）。
class SheMemoryDbService {
  SheMemoryDbService._internal();
  static final SheMemoryDbService _instance = SheMemoryDbService._internal();
  factory SheMemoryDbService() => _instance;

  static SheMemoryDbService get instance => _instance;

  Database? _database;
  String? _scopedAccountId;

  static const int _dbVersion = 1;
  static const String _dbName = 'she_memory.db';

  Future<void> switchAccount(String? accountId) async {
    if (_scopedAccountId == accountId && _database != null) return;
    await close();
    _scopedAccountId = accountId;
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<String> _resolveDbPath() async {
    if (kIsWeb) return 'she_memory';

    final directory = await getApplicationDocumentsDirectory();
    final accountId = _scopedAccountId;
    if (accountId != null && accountId.isNotEmpty) {
      final accountDir = Directory(join(directory.path, 'accounts', accountId));
      if (!accountDir.existsSync()) await accountDir.create(recursive: true);
      return join(accountDir.path, _dbName);
    }
    return join(directory.path, _dbName);
  }

  Future<Database> _initDatabase() async {
    if (kIsWeb) {
      return await openDatabase(
        'she_memory',
        version: _dbVersion,
        onCreate: _onCreate,
      );
    }

    final path = await _resolveDbPath();
    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE she_memory (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        key        TEXT NOT NULL UNIQUE,
        value      TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_she_memory_key ON she_memory(key)');
  }

  Future<String?> getSheMemory(String key) async {
    final db = await database;
    final results = await db.query(
      'she_memory',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return results.isEmpty ? null : results.first['value'] as String?;
  }

  Future<void> setSheMemory(String key, String value) async {
    final db = await database;
    await db.insert(
      'she_memory',
      {
        'key': key,
        'value': value,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, String>> getAllSheMemory() async {
    final db = await database;
    final results = await db.query('she_memory');
    return {
      for (final row in results)
        row['key'] as String: row['value'] as String,
    };
  }

  Future<void> deleteSheMemory(String key) async {
    final db = await database;
    await db.delete('she_memory', where: 'key = ?', whereArgs: [key]);
  }

  Future<void> clearSheMemory() async {
    final db = await database;
    await db.delete('she_memory');
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  Future<void> deleteDatabase() async {
    await close();
    if (!kIsWeb) {
      final path = await _resolveDbPath();
      try {
        await databaseFactory.deleteDatabase(path);
      } catch (_) {}
    }
  }
}
