import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/local_user_identity.dart';
import 'package:shepaw/services/session/dm_session_create_service.dart';
import 'package:shepaw/services/session/host_session_switch_card.dart';

import '../../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  Future<void> seedChannel(LocalDatabaseService db, String id) async {
    await db.createChannel(
      Channel(
        id: id,
        name: 'Chat',
        type: 'dm',
        members: [
          ChannelMember(
            id: LocalUserIdentity.id,
            type: 'user',
            role: 'member',
            joinedAt: 1,
          ),
        ],
      ),
      LocalUserIdentity.id,
    );
  }

  Map<String, dynamic> action(String newId, {String kind = 'dm'}) => {
        'type': 'switch',
        'kind': kind,
        'new_session_id': newId,
        'source_session_id': 'dm_source',
        'reason': 'user_requested',
        'status': 'pending',
        'created_at_ms': DateTime.now().millisecondsSinceEpoch,
      };

  test('DM card lands in the local source channel and rewrites the target id',
      () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final source = 'dm_source_$suffix';
    final hostNew = 'dm_host_new_$suffix';
    await seedChannel(db, source);

    final ok = await attachHostSessionSwitchCard(
      channelId: source,
      sessionAction: {
        ...action(hostNew),
        'source_session_id': source,
      },
      db: db,
      notify: (_) {},
    );
    expect(ok, isTrue);

    final rows = await db.getChannelMessages(source, limit: 10);
    final card = rows.cast<Map<String, dynamic>>().firstWhere(
          (row) => '${row['id']}'.startsWith('session_switch_'),
        );
    final payload = jsonDecode(card['metadata'] as String)[
        DmSessionCreateService.metaActionKey] as Map<String, dynamic>;
    expect(payload['new_session_id'], 'psess_$hostNew');
    expect(payload['host_session_id'], hostNew);
    expect(payload['source_channel_id'], source);
  });

  test('DM card uses the psess_ source when the bare id is absent', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final hostSource = 'dm_psess_source_$suffix';
    final localSource = 'psess_$hostSource';
    await seedChannel(db, localSource);

    await attachHostSessionSwitchCard(
      channelId: hostSource,
      sessionAction: {
        ...action('dm_new_$suffix'),
        'source_session_id': hostSource,
      },
      db: db,
      notify: (_) {},
    );
    final rows = await db.getChannelMessages(localSource, limit: 10);
    expect(rows.length, 1);
  });

  test('group card keeps the host session id for GroupSessionSelection',
      () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final source = 'group_$suffix';
    await seedChannel(db, source);

    await attachHostSessionSwitchCard(
      channelId: source,
      sessionAction: {
        ...action('s_group_new', kind: 'group'),
        'source_session_id': source,
      },
      db: db,
      notify: (_) {},
    );
    final rows = await db.getChannelMessages(source, limit: 10);
    final payload = (jsonDecode(rows.first['metadata'] as String)
        as Map)[DmSessionCreateService.metaActionKey];
    expect(payload['new_session_id'], 's_group_new');
  });

  test('replayed old switch events do not reinsert a deleted card', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final source = 'dm_old_$suffix';
    await seedChannel(db, source);

    final ok = await attachHostSessionSwitchCard(
      channelId: source,
      sessionAction: {
        ...action('dm_new_$suffix'),
        'source_session_id': source,
        'created_at_ms': DateTime.now().millisecondsSinceEpoch - 3600000,
      },
      db: db,
      notify: (_) {},
    );
    expect(ok, isFalse);
    expect(await db.getChannelMessages(source, limit: 10), isEmpty);
  });
}
