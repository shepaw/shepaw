import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  group('unread count excludes in-flight streaming rows', () {
    late LocalDatabaseService db;
    late String channelId;
    late String agentId;

    setUp(() async {
      db = LocalDatabaseService();
      await db.database;

      final suffix = DateTime.now().microsecondsSinceEpoch;
      channelId = 'dm_user_agent-$suffix';
      agentId = 'agent-$suffix';

      await db.createChannel(
        Channel.withMemberIds(
          id: channelId,
          name: 'Test DM',
          type: 'dm',
          memberIds: ['user', agentId],
          isPrivate: true,
        ),
        'user',
      );
    });

    test('streaming partial is not counted; finalized agent reply is', () async {
      await db.upsertPartialStreamingMessage(
        existingMessageId: null,
        channelId: channelId,
        senderId: agentId,
        senderName: 'Agent',
        content: 'partial output...',
        replyToId: 'user-msg-1',
      );

      expect(await db.getUnreadCountByChannel(channelId), 0);
      expect(await db.getUnreadCountForAgent(agentId), 0);

      await db.createMessage(
        id: 'final-msg-1',
        channelId: channelId,
        senderId: agentId,
        senderType: 'agent',
        senderName: 'Agent',
        content: 'final reply',
        metadata: {'status': 'completed'},
      );

      expect(await db.getUnreadCountByChannel(channelId), 1);
      expect(await db.getUnreadCountForAgent(agentId), 1);
    });

    test('completed unread rows with null metadata still count', () async {
      await db.createMessage(
        id: 'plain-unread',
        channelId: channelId,
        senderId: agentId,
        senderType: 'agent',
        senderName: 'Agent',
        content: 'hello',
      );

      expect(await db.getUnreadCountByChannel(channelId), 1);
    });

    test('partial status is excluded like streaming', () async {
      await db.createMessage(
        id: 'partial-row',
        channelId: channelId,
        senderId: agentId,
        senderType: 'agent',
        senderName: 'Agent',
        content: 'wip',
        metadata: {'status': 'partial'},
      );

      expect(await db.getUnreadCountByChannel(channelId), 0);
    });

    test('user messages are never counted as unread', () async {
      await db.createMessage(
        id: 'user-msg',
        channelId: channelId,
        senderId: 'user',
        senderType: 'user',
        senderName: 'User',
        content: 'question',
        isRead: 0,
      );

      expect(await db.getUnreadCountByChannel(channelId), 0);
    });

    test('getUnreadCountForAgentExcludingChannel skips streaming in other sessions', () async {
      final otherSuffix = DateTime.now().microsecondsSinceEpoch;
      final otherChannelId = 'dm_user_agent-other-$otherSuffix';
      await db.createChannel(
        Channel.withMemberIds(
          id: otherChannelId,
          name: 'Other DM',
          type: 'dm',
          memberIds: ['user', agentId],
          isPrivate: true,
        ),
        'user',
      );

      await db.createMessage(
        id: 'other-final',
        channelId: otherChannelId,
        senderId: agentId,
        senderType: 'agent',
        senderName: 'Agent',
        content: 'done',
        metadata: jsonDecode('{"status":"completed"}') as Map<String, dynamic>,
      );

      await db.upsertPartialStreamingMessage(
        existingMessageId: null,
        channelId: channelId,
        senderId: agentId,
        senderName: 'Agent',
        content: 'still streaming',
        replyToId: 'user-msg-2',
      );

      expect(
        await db.getUnreadCountForAgentExcludingChannel(agentId, channelId),
        1,
      );
    });
  });
}
