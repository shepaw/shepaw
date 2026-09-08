import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  group('searchChannels', () {
    late LocalDatabaseService db;
    const userId = 'user';
    final stamp = DateTime.now().microsecondsSinceEpoch;

    setUp(() async {
      db = LocalDatabaseService();
      await db.database;
    });

    Future<void> createChannel(String id, String name, String? description) {
      return db.createChannel(
        Channel(
          id: id,
          name: name,
          description: description,
          type: 'group',
          members: const [],
          createdBy: userId,
        ),
        userId,
      );
    }

    test('matches channel name', () async {
      final id = 'ch_search_name_$stamp';
      await createChannel(id, 'Alpha Team', null);

      final results = await db.searchChannels('Alpha Team');
      expect(results.map((c) => c.id), contains(id));
    });

    test('matches channel description', () async {
      final id = 'ch_search_desc_$stamp';
      await createChannel(id, 'Plain Name', 'weekly sync notes');

      final results = await db.searchChannels('sync notes');
      expect(results.map((c) => c.id), contains(id));
    });

    test('is case-insensitive for ASCII', () async {
      final id = 'ch_search_case_$stamp';
      await createChannel(id, 'GitHub Bot', null);

      expect(await db.searchChannels('github'), isNotEmpty);
      expect(
        (await db.searchChannels('github')).map((c) => c.id),
        contains(id),
      );
    });

    test('returns empty for blank query', () async {
      final id = 'ch_search_blank_$stamp';
      await createChannel(id, 'Blank Query Target', null);

      expect(await db.searchChannels(''), isEmpty);
      expect(await db.searchChannels('   '), isEmpty);
    });

    test('respects the limit', () async {
      final prefix = 'ch_search_limit_${stamp}_';
      for (var i = 0; i < 3; i++) {
        await createChannel('$prefix$i', 'Limited Match $i', null);
      }

      final results = await db.searchChannels('Limited Match', limit: 2);
      expect(results.length, 2);
    });
  });
}
