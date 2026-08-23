import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/agent.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  group('AgentDao bio round-trip', () {
    late LocalDatabaseService db;
    late String ownerId;

    setUp(() async {
      db = LocalDatabaseService();
      await db.database;
      ownerId = 'user';
    });

    Agent buildAgent({
      required String id,
      String? bio,
      String? description,
    }) {
      return Agent(
        id: id,
        name: 'Test Agent',
        avatar: '🤖',
        bio: bio,
        description: description,
        provider: const AgentProvider(name: 'local', platform: 'local', type: 'llm'),
        status: const AgentStatus(state: 'offline'),
      );
    }

    test('read back populates both bio and description from the bio column',
        () async {
      final id = 'agent-bio-${DateTime.now().microsecondsSinceEpoch}';
      await db.createAgent(buildAgent(id: id, bio: '我的简历'), ownerId);

      final loaded = await db.getAgentById(id);
      expect(loaded, isNotNull);
      expect(loaded!.bio, '我的简历');
      expect(loaded.description, '我的简历');
    });

    test('legacy description-only write still round-trips', () async {
      final id = 'agent-desc-${DateTime.now().microsecondsSinceEpoch}';
      await db.createAgent(buildAgent(id: id, description: '旧版描述'), ownerId);

      final loaded = await db.getAgentById(id);
      expect(loaded, isNotNull);
      expect(loaded!.bio, '旧版描述');
      expect(loaded.description, '旧版描述');
    });

    test('update persists bio and read back keeps both fields', () async {
      final id = 'agent-upd-${DateTime.now().microsecondsSinceEpoch}';
      await db.createAgent(buildAgent(id: id, bio: '初始'), ownerId);

      await db.updateAgent(buildAgent(id: id, bio: '更新后的简历'));
      final loaded = await db.getAgentById(id);
      expect(loaded, isNotNull);
      expect(loaded!.bio, '更新后的简历');
      expect(loaded.description, '更新后的简历');
    });
  });
}
