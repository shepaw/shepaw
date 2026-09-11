import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/chat/chat_namespace.dart';
import 'package:shepaw/clis/shepaw/chat/session/session_create_command.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/cli_namespace_registry.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/local_user_identity.dart';
import 'package:shepaw/services/session/dm_session_create_service.dart';

import '../../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  test('chat help lists session.create', () {
    final help = ChatNamespace.instance.getHelp();
    expect(
      (help['sub_namespaces'] as Map).containsKey('session'),
      isTrue,
    );
    expect(
      CliNamespaceRegistry.instance.allCommandIds,
      contains('chat.session.create'),
    );
  });

  test('command help describes summary + reason', () {
    final help = ChatSessionCreateCommand().getHelp();
    expect(help['command'], 'create');
    final flags = help['flags'] as Map<String, dynamic>;
    expect(flags['reason'], isNotNull);
    expect(flags['summary'], isNotNull);
  });

  test('rejects missing reason / summary', () async {
    final cmd = ChatSessionCreateCommand(
      service: DmSessionCreateService(notifyChannelUpdate: (_) {}),
    );
    expect(
      (await cmd.execute({'channel': 'dm_x'}))['error'],
      contains('--reason'),
    );
    expect(
      (await cmd.execute({'channel': 'dm_x', 'reason': 'topic_shift'}))['error'],
      contains('--summary'),
    );
  });

  test('CLI create writes session_action for the switch card', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'coder_$suffix';
    final channelId = 'dm_cli_$suffix';
    await db.createChannel(
      Channel(
        id: channelId,
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
      ),
      LocalUserIdentity.id,
    );

    final cmd = ChatSessionCreateCommand(
      service: DmSessionCreateService(
        db: db,
        notifyChannelUpdate: (_) {},
      ),
    );
    final result = await cmd.execute({
      'channel': channelId,
      'reason': 'context_too_long',
      'summary': 'Keep the auth token flow',
      'agent_id': agentId,
      'agent_name': 'Coder',
    });

    expect(result['status'], 'ok');
    expect(result['new_session_id'], isNotEmpty);
    expect(result['session_action'], isA<Map>());
    expect(
      (result['session_action'] as Map)['new_session_id'],
      result['new_session_id'],
    );
  });
}
