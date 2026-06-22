import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

/// 独立的 She 档案数据库服务（按账号隔离路径）。
class SheProfileDatabaseService {
  static final SheProfileDatabaseService _instance =
      SheProfileDatabaseService._internal();
  factory SheProfileDatabaseService() => _instance;
  SheProfileDatabaseService._internal();

  Database? _database;
  String? _scopedAccountId;

  static const int _version = 2;
  static const String _dbName = 'she_profile.db';

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
    if (kIsWeb) return 'she_profile';

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
        'she_profile',
        version: _version,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    }

    final path = await _resolveDbPath();
    return await openDatabase(
      path,
      version: _version,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
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

    await db.execute('''
      CREATE TABLE user_profile (
        key        TEXT PRIMARY KEY,
        value      TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {}

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

  Future<String?> getUserProfile(String key) async {
    final db = await database;
    final results = await db.query(
      'user_profile',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return results.isEmpty ? null : results.first['value'] as String?;
  }

  Future<void> setUserProfile(String key, String value) async {
    final db = await database;
    await db.insert(
      'user_profile',
      {
        'key': key,
        'value': value,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, String>> getAllUserProfile() async {
    final db = await database;
    final results = await db.query('user_profile', orderBy: 'key ASC');
    return {
      for (final row in results)
        row['key'] as String: row['value'] as String,
    };
  }

  Future<void> deleteUserProfile(String key) async {
    final db = await database;
    await db.delete('user_profile', where: 'key = ?', whereArgs: [key]);
  }

  Future<void> clearSheMemory() async {
    final db = await database;
    await db.delete('she_memory');
  }

  Future<void> clearUserProfile() async {
    final db = await database;
    await db.delete('user_profile');
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.delete('she_memory');
    await db.delete('user_profile');
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
