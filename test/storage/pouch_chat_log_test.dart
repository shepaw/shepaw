import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/pouch_chat_log.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pouch_chat_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  PouchChatRecord record(String id, String content) {
    return PouchChatRecord(
      id: id,
      channelId: 'ch-1',
      senderId: 'u',
      senderType: 'user',
      senderName: '我',
      content: content,
      messageType: 'text',
      createdAt: '2026-09-29T00:00:00.000',
    );
  }

  test('连续更新同一条消息只留最后一版', () async {
    final log = PouchChatLog(root);
    await log.upsert(record('m1', '你好'));
    await log.upsert(record('m1', '你好呀'));
    final lines = await log.fileFor('ch-1').readAsLines();
    expect(lines, hasLength(1));
    final read = await log.readChannel('ch-1');
    expect(read, hasLength(1));
    expect(read.single.content, '你好呀');
  });

  test('不同消息按写入顺序保留，删除的不再读出', () async {
    final log = PouchChatLog(root);
    await log.upsert(record('m1', '一'));
    await log.upsert(record('m2', '二'));
    await log.tombstone(channelId: 'ch-1', messageId: 'm1');
    final read = await log.readChannel('ch-1');
    expect(read.map((m) => m.id), ['m2']);
  });

  test('删掉整个频道会去掉日志文件', () async {
    final log = PouchChatLog(root);
    await log.upsert(record('m1', '一'));
    expect(log.fileFor('ch-1').existsSync(), isTrue);
    await log.deleteChannel('ch-1');
    expect(log.fileFor('ch-1').existsSync(), isFalse);
    expect(await log.readChannel('ch-1'), isEmpty);
  });
}
