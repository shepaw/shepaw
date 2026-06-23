import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/utils/app_cache_utils.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return Directory.systemTemp.createTempSync('shepaw_cache_test').path;
      }
      return null;
    });
  });

  group('message cache maxBytes', () {
    late LocalDatabaseService db;

    setUp(() async {
      db = LocalDatabaseService();
      await db.close();
      await db.switchAccount('test-cache-${DateTime.now().microsecondsSinceEpoch}');
      await db.database;
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> insertMessage(String id, String content) async {
      final now = DateTime.now().toIso8601String();
      await db.upsertMessageFromSync({
        'id': id,
        'channel_id': 'ch-1',
        'sender_id': 'u1',
        'sender_name': 'User',
        'content': content,
        'created_at': now,
        'updated_at': now,
      });
    }

    test('trimMessagesToPolicy evicts oldest when over maxBytes', () async {
      await insertMessage('m1', 'a' * 100);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await insertMessage('m2', 'b' * 100);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await insertMessage('m3', 'c' * 100);

      final before = await db.totalCachedMessageBytes();
      expect(before, greaterThan(200));

      await db.trimMessagesToPolicy(200, 365, maxBytes: 220);

      final remaining = await db.database.then((d) => d.query('messages', orderBy: 'id ASC'));
      expect(remaining.length, lessThan(3));
      expect(await db.totalCachedMessageBytes(), lessThanOrEqualTo(220));
      expect(remaining.first['id'], isNot('m1'));
    });

    test('estimateMessageRowBytes counts utf8 payload', () {
      expect(
        AppCacheUtils.estimateMessageRowBytes({'content': 'hello', 'metadata': ''}),
        5,
      );
      expect(
        AppCacheUtils.estimateMessageRowBytes({'content': '你好', 'metadata': ''}),
        6,
      );
    });
  });
}
