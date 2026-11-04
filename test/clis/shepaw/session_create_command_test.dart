import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/chat/chat_namespace.dart';
import 'package:shepaw/clis/shepaw/chat/session/session_create_command.dart';
import 'package:shepaw/peer/services/hub_session_create.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/services/cli_namespace_registry.dart';
import 'package:shepaw/services/local_database_service.dart';

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
      host: HubSessionCreate(peerId: 'peer-1'),
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

  test('CLI create sends the request to the host and returns its switch action',
      () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    Map<String, dynamic>? sent;
    final host = HubSessionCreate(
      peerId: 'peer-1',
      events: incoming.stream,
      send: (peerId, frame) async {
        sent = Map<String, dynamic>.from(frame);
        incoming.add(PeerControlEvent(
          peerId: peerId,
          data: {
            'type': 'session_create_resp',
            'request_id': frame['request_id'],
            'success': true,
            'status': 'ok',
            'new_session_id': 'dm_new_1',
            'session_action': {
              'type': 'switch',
              'new_session_id': 'dm_new_1',
              'source_session_id': frame['channel_id'],
              'reason': 'context_too_long',
              'status': 'pending',
            },
          },
        ));
        return true;
      },
    );

    final result = await ChatSessionCreateCommand(host: host).execute({
      'channel': 'dm_x',
      'reason': 'context_too_long',
      'summary': 'Keep the auth token flow',
      'agent_id': 'coder',
      'call_token': 'tok-1',
    });

    expect(result['success'], isTrue);
    expect(result['session_action'], isA<Map>());
    expect(
      (result['session_action'] as Map)['new_session_id'],
      result['new_session_id'],
    );
    expect(sent, isNotNull);
    expect(sent!['kind'], 'dm');
    expect(sent!['channel_id'], 'dm_x');
    expect(sent!['agent_id'], 'coder');
    expect(sent!['call_token'], 'tok-1');
    expect(sent!['summary'], 'Keep the auth token flow');
    expect(sent!['suggest_switch'], isTrue);
    await incoming.close();
  });
}
