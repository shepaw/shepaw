import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  group('getFirstChannelMessage (会话列表标题用首句)', () {
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

    test('gmd 成员会话：系统说明消息被跳过，返回第一条真实消息', () async {
      // 群聊绑定成员会话创建时写入的系统说明（group_member_session_service）。
      await db.createMessage(
        id: 'sys-intro',
        channelId: channelId,
        senderId: 'system',
        senderType: 'system',
        senderName: 'System',
        content: '本会话由群聊「Team」自动创建，与该群会话一一对应。'
            '此处记录对该成员的每次调用（请求与回复），不会影响普通单聊上下文。',
        messageType: 'system',
        createdAt: DateTime(2026, 8, 21, 10, 0, 0),
      );

      // 只有系统消息时：无真实首条消息，调用方回退到会话名。
      expect(await db.getFirstChannelMessage(channelId), isNull);

      await db.createMessage(
        id: 'first-request',
        channelId: channelId,
        senderId: 'user',
        senderType: 'user',
        senderName: 'User',
        content: '帮我总结一下今天的进展',
        createdAt: DateTime(2026, 8, 21, 10, 0, 1),
      );

      final first = await db.getFirstChannelMessage(channelId);
      expect(first, isNotNull);
      expect(first!['id'], 'first-request');
      expect(first['content'], '帮我总结一下今天的进展');
    });

    test('permission_audit 同样被跳过', () async {
      await db.createMessage(
        id: 'audit-1',
        channelId: channelId,
        senderId: 'system',
        senderType: 'system',
        senderName: 'System',
        content: 'permission audit entry',
        messageType: 'permission_audit',
        createdAt: DateTime(2026, 8, 21, 10, 0, 0),
      );
      await db.createMessage(
        id: 'real-1',
        channelId: channelId,
        senderId: 'agent',
        senderType: 'agent',
        senderName: 'Agent',
        content: 'real reply',
        createdAt: DateTime(2026, 8, 21, 10, 0, 1),
      );

      final first = await db.getFirstChannelMessage(channelId);
      expect(first, isNotNull);
      expect(first!['id'], 'real-1');
    });

    test('普通会话保持字面第一条消息', () async {
      await db.createMessage(
        id: 'plain-first',
        channelId: channelId,
        senderId: 'user',
        senderType: 'user',
        senderName: 'User',
        content: 'hello',
        createdAt: DateTime(2026, 8, 21, 10, 0, 0),
      );
      await db.createMessage(
        id: 'plain-second',
        channelId: channelId,
        senderId: 'agent',
        senderType: 'agent',
        senderName: 'Agent',
        content: 'hi',
        createdAt: DateTime(2026, 8, 21, 10, 0, 1),
      );

      final first = await db.getFirstChannelMessage(channelId);
      expect(first, isNotNull);
      expect(first!['id'], 'plain-first');
      expect(first['content'], 'hello');
    });
  });
}
