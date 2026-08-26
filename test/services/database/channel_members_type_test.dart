import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  group('getChannelMembers distinguishes user vs agent (H3)', () {
    late LocalDatabaseService db;
    late String userId;

    setUp(() async {
      db = LocalDatabaseService();
      await db.database;
      userId = 'local-user-123';
    });

    RemoteAgent buildAgent(String id, String name) => RemoteAgent(
          id: id,
          name: name,
          avatar: '🤖',
          token: 't',
          endpoint: 'http://localhost',
          protocol: ProtocolType.acp,
          connectionType: ConnectionType.http,
          createdAt: 0,
          updatedAt: 0,
        );

    test('reload types members by presence in the agents table', () async {
      // A real agent lives in the agents table; the local user does not.
      await db.createRemoteAgent(buildAgent('agent-coder', 'Coder'));

      const channelId = 'group_chan_h3';
      await db.createChannel(
        Channel(
          id: channelId,
          name: 'H3 Group',
          type: 'group',
          members: [
            ChannelMember(
                id: 'agent-coder', type: 'agent', role: 'member', joinedAt: 0),
            ChannelMember(
                id: 'local-user-123',
                type: 'user',
                role: 'member',
                joinedAt: 0),
          ],
          createdBy: userId,
        ),
        userId,
      );

      final members = await db.getChannelMembers(channelId);
      final byId = {for (final m in members) m.id: m};
      // The stored type column does not exist in channel_members; type must be
      // reconstructed from the agents table — not hardcoded to 'agent'.
      expect(byId['agent-coder']!.isAgent, isTrue);
      expect(byId['local-user-123']!.isUser, isTrue);
      expect(byId['local-user-123']!.isAgent, isFalse);

      // Channel.agentIds must exclude the local user (ghost DM / workspace /
      // dispatch / "last agent" guard all rely on this).
      final channel = await db.getChannelById(channelId);
      expect(channel!.agentIds, ['agent-coder']);
      expect(channel.memberIds, contains('local-user-123'));
    });

    test('returns empty for a channel with no members', () async {
      const channelId = 'group_chan_h3_empty';
      await db.createChannel(
        Channel(
          id: channelId,
          name: 'Empty',
          type: 'group',
          members: const [],
          createdBy: userId,
        ),
        userId,
      );
      expect(await db.getChannelMembers(channelId), isEmpty);
    });
  });
}
