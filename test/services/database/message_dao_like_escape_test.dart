import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/peer_approval_payload.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:sqflite/sqflite.dart';

import '../../storage/test_harness.dart';

/// `hostChannelIdForCard` 退回全库子串扫描时用的 LIKE 转义：approval_id
/// 常带 `_`，不转义会把别的卡片行也捞进来，归属出现假歧义。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await StorageTestHarness.init();
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      getIt.registerSingleton<LocalDatabaseService>(LocalDatabaseService());
    }
    await LocalDatabaseService().database;
  });

  late LocalDatabaseService db;

  setUp(() async {
    db = LocalDatabaseService();
    await db.getMessageById('__warmup__'); // 确保建表
  });

  Future<void> insert(String id, String metadata) async {
    final d = await db.database;
    await d.insert('messages', {
      'id': id,
      'channel_id': 'ch-1',
      'sender_id': 'agent-1',
      'sender_type': 'agent',
      'sender_name': 'Agent',
      'content': '',
      'message_type': 'text',
      'created_at': 0,
      'metadata': metadata,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  test('转义后 _ 与 % 按字面匹配，不会命中不相干的行', () async {
    await insert('row-real', '{"card_channel_id":"dm_a","form_id":"ap_1_x"}');
    // 同一前缀但下划线位置不同：不转义时 LIKE '%ap_1_x%' 会把它也捞进来。
    await insert('row-other', '{"card_channel_id":"dm_b","form_id":"apZ1Zx"}');
    await insert('row-percent', '{"card_channel_id":"dm_c","form_id":"ap%1"}');

    final escaped =
        await db.findMessagesByMetadataMatch('ap_1_x', escapeWildcards: true);
    expect(escaped.map((r) => r['id']).toList(), ['row-real'],
        reason: '_ 必须按字面量匹配');

    final pct = await db.findMessagesByMetadataMatch('ap%1', escapeWildcards: true);
    expect(pct.map((r) => r['id']).toList(), ['row-percent'],
        reason: '% 必须按字面量匹配');

    // 未转义的旧口径仍然可用（_isPersistedOpenForm 之外的调用方）。
    final raw = await db.findMessagesByMetadataMatch('ap_1_x');
    expect(raw.map((r) => r['id']), containsAll(['row-real', 'row-other']),
        reason: '旧口径确实会把 _ 当通配符，证明转义是必要的');
  });

  test('hostChannelIdForCard 用确定性行取归属，忽略同 id 子串的干扰行', () async {
    // 确定性卡片行带归属。
    await insert(
      PeerApprovalPayload.formCardMessageId('ap_2_x'),
      '{"form":{"form_id":"ap_2_x","peer_form":{"approval_id":"ap_2_x"}},'
          '"card_channel_id":"dm_a"}',
    );
    // 不相干行里恰好出现了同一子串，但归属不同；确定性行优先，不应造成歧义。
    await insert('row-noise',
        '{"form":{"form_id":"apZ2Zx"},"card_channel_id":"dm_b"}');

    final channel = await PeerAgentClientService.instance
        .hostChannelIdForCard('ap_2_x');
    expect(channel, 'dm_a');
  });

  test('同一行的并发 merge 串行执行，两个 patch 都保留', () async {
    await insert('row-merge', '{"form":{"form_id":"m1"},"card_peer_id":"peer-1"}');

    // 两个 patch 同时发起：重连补发的 onForm（写 card_channel_id）与轮询的
    // answered_elsewhere（写 form.closed）。无串行链时后写者会整份覆盖。
    await Future.wait([
      db.mergeMessageMetadata('row-merge', {
        'form': {'form_id': 'm1'},
        'card_channel_id': 'dm_a',
      }),
      db.mergeMessageMetadata('row-merge', {
        'form': {'form_id': 'm1', 'closed': 'answered_elsewhere'},
      }),
    ]);

    final row = await db.getMessageById('row-merge');
    final meta = jsonDecode(row!['metadata'] as String) as Map;
    expect(meta['card_channel_id'], 'dm_a',
        reason: '归属不能被另一个 patch 抹掉');
    expect((meta['form'] as Map)['closed'], 'answered_elsewhere',
        reason: 'closed 不能被另一个 patch 抹掉');
    expect(meta['card_peer_id'], 'peer-1');
  });
}
