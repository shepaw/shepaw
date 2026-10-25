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

  late LocalDatabaseService db;
  late String channelId;
  late String messageId;

  setUp(() async {
    db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch;
    channelId = 'dm_user_agent-$suffix';
    messageId = 'msg-$suffix';
    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'Test DM',
        type: 'dm',
        memberIds: ['user', 'agent-$suffix'],
        isPrivate: true,
      ),
      'user',
    );
    await db.createMessage(
      id: messageId,
      channelId: channelId,
      senderId: 'user',
      senderType: 'user',
      senderName: 'U',
      content: 'hi',
      messageType: 'text',
      metadata: <String, dynamic>{
        'pouch_uri': 'pouch://runtime/a/attachments/h',
        'name': 'a.txt',
      },
    );
  });

  Future<Map<String, dynamic>> metadata() async {
    final row = await db.getMessageById(messageId);
    return jsonDecode(row!['metadata'] as String) as Map<String, dynamic>;
  }

  test('mergeMessageMetadata 只补 patch 里的 key，不覆盖已有字段', () async {
    await db.mergeMessageMetadata(messageId, {
      'pouch_uri_scoped': 'pouch://p1/agent:a1/files/attachments/h',
    });

    final meta = await metadata();
    expect(meta['pouch_uri'], 'pouch://runtime/a/attachments/h');
    expect(meta['name'], 'a.txt');
    expect(
      meta['pouch_uri_scoped'],
      'pouch://p1/agent:a1/files/attachments/h',
    );
  });

  test('消息不存在时不写也不抛', () async {
    await db.mergeMessageMetadata('missing-id', {'x': 1});
    expect(await db.getMessageById('missing-id'), isNull);
  });
}
