import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  /// 造一个群家族：根群 `root`（也是家族），下面挂两个子会话。
  Future<({String family, List<String> children})> seedFamily(
    LocalDatabaseService db,
    String suffix,
  ) async {
    final family = 'g_root_$suffix';
    await db.createChannel(
      Channel.withMemberIds(
        id: family,
        name: 'Root',
        type: 'group',
        memberIds: ['user', 'agent-a-$suffix'],
      ),
      'user',
    );
    final children = <String>[];
    for (final i in [1, 2]) {
      final id = 'g_sub_${i}_$suffix';
      await db.createChannel(
        Channel.withMemberIds(
          id: id,
          name: 'Sub $i',
          type: 'group',
          memberIds: ['user', 'agent-a-$suffix'],
          parentGroupId: family,
        ),
        'user',
      );
      children.add(id);
    }
    return (family: family, children: children);
  }

  test('批量群家族查询与逐个查的结果一致', () async {
    final db = LocalDatabaseService();
    await db.database;
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final seed = await seedFamily(db, '$suffix');
    final other = await seedFamily(db, '${suffix}_b');

    // 给第一个家族的子会话写消息，制造「最新一条」和 updated_at 差异。
    await db.createMessage(
      id: 'm1_$suffix',
      channelId: seed.children.first,
      senderId: 'agent-a-$suffix',
      senderName: 'A',
      senderType: 'agent',
      content: 'first',
      messageType: 'text',
      createdAt: DateTime.parse('2026-10-01T10:00:00Z'),
    );
    await db.createMessage(
      id: 'm2_$suffix',
      channelId: seed.children.last,
      senderId: 'agent-a-$suffix',
      senderName: 'A',
      senderType: 'agent',
      content: 'second',
      messageType: 'text',
      createdAt: DateTime.parse('2026-10-02T10:00:00Z'),
    );

    final families = [seed.family, other.family];

    final batchSessions = await db.getGroupSessionIdsByFamilies(families);
    for (final family in families) {
      expect(
        (batchSessions[family] ?? const []).toSet(),
        (await db.getGroupSessionIds(family)).toSet(),
        reason: 'session ids mismatch for $family',
      );
    }

    final batchActive = await db.getLatestActiveGroupChannels(families);
    for (final family in families) {
      expect(
        batchActive[family],
        await db.getLatestActiveGroupChannel(family),
        reason: 'active channel mismatch for $family',
      );
    }

    final batchLatest = await db.getLatestMessagesForGroupFamilies(families);
    for (final family in families) {
      final expected = await db.getLatestMessageForGroupFamily(family);
      expect(
        batchLatest[family]?['id'],
        expected?['id'],
        reason: 'latest message mismatch for $family',
      );
    }

    // 第一个家族有消息，最新那条应该是 10-02 的 m2。
    expect(batchLatest[seed.family]?['id'], 'm2_$suffix');
    // 第二个家族没有任何消息，批量结果里不该有它。
    expect(batchLatest.containsKey(other.family), isFalse);
  });

  test('空家族列表不查库', () async {
    final db = LocalDatabaseService();
    await db.database;
    expect(await db.getGroupSessionIdsByFamilies(const []), isEmpty);
    expect(await db.getLatestActiveGroupChannels(const []), isEmpty);
    expect(await db.getLatestMessagesForGroupFamilies(const []), isEmpty);
  });
}
