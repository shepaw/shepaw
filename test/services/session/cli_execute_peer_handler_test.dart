import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/session/cli_execute_peer_handler.dart';

RemoteAgent _hubEngine() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return RemoteAgent(
    id: 'h1',
    name: 'Cursor',
    token: 't',
    endpoint: '',
    protocol: ProtocolType.peer,
    connectionType: ConnectionType.http,
    createdAt: now,
    updatedAt: now,
    metadata: const {
      'source_peer_id': 'peer1',
      'remote_agent_id': 'inst-1',
      'manageable': true,
      'engine': 'cursor',
    },
  );
}

RemoteAgent _phonePeer() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return RemoteAgent(
    id: 'p1',
    name: 'Coder',
    token: 't',
    endpoint: '',
    protocol: ProtocolType.peer,
    connectionType: ConnectionType.http,
    createdAt: now,
    updatedAt: now,
    metadata: const {
      'llm_provider': 'openai',
      'source_peer_id': 'peer1',
    },
  );
}

void main() {
  group('PeerCliExecuteHandler', () {
    test('rejects missing agent_id and namespace', () async {
      final h = PeerCliExecuteHandler(
        lookupAgent: (_) async => _hubEngine(),
        run: ({required agentId, params}) async => {'ok': true},
      );
      expect(
        await h.handle({'namespace': 'store', 'subcommand': 'read'}),
        {'ok': false, 'error': 'missing agent_id'},
      );
      expect(
        await h.handle({'agent_id': 'h1'}),
        {'ok': false, 'error': 'missing namespace'},
      );
    });

    test('rejects unknown and non-Hub agents', () async {
      final h = PeerCliExecuteHandler(
        lookupAgent: (id) async => id == 'p1' ? _phonePeer() : null,
        run: ({required agentId, params}) async => {'ok': true},
      );
      expect(
        await h.handle({
          'agent_id': 'missing',
          'namespace': 'store',
        }),
        {'ok': false, 'error': 'unknown agent'},
      );
      expect(
        await h.handle({
          'agent_id': 'p1',
          'namespace': 'os',
          'subcommand': 'file.read',
        }),
        {'ok': false, 'error': 'agent is not a Hub engine'},
      );
    });

    test('forwards Hub engines through the CLI gate runner', () async {
      Map<String, dynamic>? seen;
      final h = PeerCliExecuteHandler(
        lookupAgent: (_) async => _hubEngine(),
        run: ({required agentId, params}) async {
          seen = {'agentId': agentId, ...?params};
          return {'ok': true, 'success': true};
        },
      );
      final out = await h.handle({
        'agent_id': 'h1',
        'namespace': 'os',
        'subcommand': 'file.read',
        'session_id': 'ch-1',
        'flags': {'path': '/tmp/a', 'agent_id': 'forged'},
      });
      expect(out, {'ok': true, 'success': true});
      expect(seen, {
        'agentId': 'h1',
        'namespace': 'os',
        'subcommand': 'file.read',
        'flags': {'path': '/tmp/a', 'agent_id': 'forged'},
        'session_id': 'ch-1',
      });
    });
  });
}
