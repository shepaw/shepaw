import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/chat_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/tool_result_database_service.dart';

import '../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
    await ToolResultDatabaseService().database;
  });

  group('ChatService.forkSession (会话分叉)', () {
    late LocalDatabaseService db;
    late String sourceId;
    late String userId;
    late String agentId;

    setUp(() async {
      db = LocalDatabaseService();
      await db.database;
      userId = 'user';
      final suffix = DateTime.now().microsecondsSinceEpoch;
      agentId = 'agent-$suffix';
      sourceId = 'dm_${[userId, agentId]..sort()}_$suffix';
      await db.createChannel(
        Channel.withMemberIds(
          id: sourceId,
          name: 'Test DM',
          type: 'dm',
          memberIds: [userId, agentId],
          isPrivate: true,
        ),
        userId,
      );
    });

    test('复制消息与工具执行历史到新会话（重写 id 与 reply_to）', () async {
      final t0 = DateTime.now().subtract(const Duration(minutes: 5));
      await db.createMessage(
        id: 'm1',
        channelId: sourceId,
        senderId: userId,
        senderType: 'user',
        senderName: 'user',
        content: 'hello',
        createdAt: t0,
      );
      await db.createMessage(
        id: 'm2',
        channelId: sourceId,
        senderId: agentId,
        senderType: 'agent',
        senderName: 'agent',
        content: 'hi',
        replyToId: 'm1',
        createdAt: t0.add(const Duration(minutes: 1)),
      );

      final toolDb = ToolResultDatabaseService();
      await toolDb.createToolExecution(
        id: 'te1',
        messageId: 'm2',
        channelId: sourceId,
        toolCallId: 'tc1',
        toolName: 'read_file',
        arguments: {'path': '/tmp/x'},
      );
      await toolDb.updateToolExecutionResult(
        toolCallId: 'tc1',
        resultType: 'text',
        summary: 'file contents',
        fullResult: '{"raw":"file contents"}',
      );

      final newId = await ChatService().forkSession(
        sourceChannelId: sourceId,
        userId: userId,
        userName: 'user',
        agentId: agentId,
        agentName: 'agent',
        isGroup: false,
      );

      expect(newId, isNot(sourceId));

      final msgs = await db.getChannelMessages(newId, limit: 100);
      expect(msgs.length, 2);
      // 消息 id 已重写，不复用源 id。
      expect(msgs.map((m) => m['id']).toSet(), isNot(contains('m1')));
      expect(msgs.map((m) => m['id']).toSet(), isNot(contains('m2')));
      expect(msgs.every((m) => m['is_read'] == 1), isTrue);

      final agentMsg = msgs.firstWhere((m) => m['content'] == 'hi');
      final replyTo = agentMsg['reply_to_id'] as String?;
      expect(replyTo, isNotNull);
      final replyTarget = msgs.firstWhere((m) => m['id'] == replyTo);
      expect(replyTarget['content'], 'hello');

      // 工具执行复制到新 channel，message_id 指向重写后的消息。
      final toolRows = await toolDb.database.then(
        (d) => d.query(
          'tool_executions',
          where: 'channel_id = ?',
          whereArgs: [newId],
        ),
      );
      expect(toolRows.length, 1);
      expect(toolRows.first['tool_name'], 'read_file');
      expect(toolRows.first['summary'], 'file contents');
      expect(toolRows.first['message_id'], agentMsg['id']);
    });

    test('空会话分叉：新会话存在但无消息', () async {
      final newId = await ChatService().forkSession(
        sourceChannelId: sourceId,
        userId: userId,
        userName: 'user',
        agentId: agentId,
        agentName: 'agent',
        isGroup: false,
      );

      expect(newId, isNot(sourceId));
      final msgs = await db.getChannelMessages(newId, limit: 100);
      expect(msgs, isEmpty);
      final channel = await db.getChannelById(newId);
      expect(channel, isNotNull);
      // 分叉后是独立普通 DM，不继承 group/She 绑定。
      expect(channel!.isGroupBoundMemberSession, isFalse);
      expect(channel.isSheBoundSession, isFalse);
    });
  });
}
