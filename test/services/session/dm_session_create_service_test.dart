import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/local_user_identity.dart';
import 'package:shepaw/services/session/dm_session_create_service.dart';

import '../../storage/test_harness.dart';

void main() {
  late LocalDatabaseService db;
  late DmSessionCreateService service;

  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  setUp(() {
    db = LocalDatabaseService();
    service = DmSessionCreateService(
      db: db,
      notifyChannelUpdate: (_) {},
    );
  });

  Future<Channel> _dm({
    required String id,
    required String agentId,
    bool boundToGroup = false,
  }) async {
    final channel = Channel(
      id: id,
      name: 'Chat with Coder',
      type: 'dm',
      members: [
        ChannelMember(
          id: LocalUserIdentity.id,
          type: 'user',
          role: 'member',
          joinedAt: 1,
        ),
        ChannelMember(
          id: agentId,
          type: 'agent',
          role: 'member',
          joinedAt: 1,
        ),
      ],
      sourceGroupChannelId: boundToGroup ? 'group_x' : null,
    );
    await db.createChannel(channel, LocalUserIdentity.id);
    return channel;
  }

  test('creates a sibling DM with handoff message and switch payload', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final source = await _dm(id: 'dm_src_$suffix', agentId: 'coder_$suffix');

    final result = await service.create(
      channelId: source.id,
      actorId: 'coder_$suffix',
      actorName: 'Coder',
      args: {
        'reason': 'context_too_long',
        'reason_detail': '上下文过长',
        'summary': '已完成登录页；下一步做列表分页',
      },
    );

    expect(result.ok, isTrue);
    expect(result.newSessionId, isNotNull);
    expect(result.newSessionId, isNot(source.id));
    expect(result.sessionAction?['type'], 'switch');
    expect(result.sessionAction?['new_session_id'], result.newSessionId);
    expect(result.sessionAction?['reason'], 'context_too_long');

    final created = await db.getChannelById(result.newSessionId!);
    expect(created, isNotNull);
    expect(created!.isDM, isTrue);
    expect(created.memberIds, contains('coder_$suffix'));

    final msgs = await db.getChannelMessages(result.newSessionId!);
    expect(msgs, isNotEmpty);
    expect(msgs.first['content'], contains('已完成登录页'));
    expect(msgs.first['content'], contains('【会话交接】'));
  });

  test('rejects group channels', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final group = Channel(
      id: 'group_$suffix',
      name: 'Team',
      type: 'group',
      members: [
        ChannelMember(
          id: 'coder_$suffix',
          type: 'agent',
          role: 'admin',
          joinedAt: 1,
        ),
      ],
    );
    await db.createChannel(group, LocalUserIdentity.id);

    final result = await service.create(
      channelId: group.id,
      actorId: 'coder_$suffix',
      actorName: 'Coder',
      args: {'reason': 'topic_shift', 'summary': 'x'},
    );
    expect(result.ok, isFalse);
    expect(result.error, contains('group session create'));
  });

  test('rejects bound relay DMs and unknown reasons', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final bound = await _dm(
      id: 'dm_bound_$suffix',
      agentId: 'coder_$suffix',
      boundToGroup: true,
    );
    final boundResult = await service.create(
      channelId: bound.id,
      actorId: 'coder_$suffix',
      actorName: 'Coder',
      args: {'reason': 'topic_shift', 'summary': 'x'},
    );
    expect(boundResult.ok, isFalse);
    expect(boundResult.error, contains('Bound relay'));

    final dm = await _dm(id: 'dm_bad_$suffix', agentId: 'coder_$suffix');
    final badReason = await service.create(
      channelId: dm.id,
      actorId: 'coder_$suffix',
      actorName: 'Coder',
      args: {'reason': 'not_a_reason', 'summary': 'x'},
    );
    expect(badReason.ok, isFalse);
    expect(badReason.error, contains('reason must be one of'));
  });
}
