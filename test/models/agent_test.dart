import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/agent.dart';

void main() {
  group('AgentProvider Tests', () {
    test('fromJson should parse correctly', () {
      final json = {
        'name': 'OpenAI',
        'platform': 'cloud',
        'type': 'llm',
        'logo': 'https://example.com/logo.png',
      };

      final provider = AgentProvider.fromJson(json);

      expect(provider.name, 'OpenAI');
      expect(provider.platform, 'cloud');
      expect(provider.type, 'llm');
      expect(provider.logo, 'https://example.com/logo.png');
    });

    test('fromJson should handle missing fields', () {
      final provider = AgentProvider.fromJson({});

      expect(provider.name, '');
      expect(provider.platform, '');
      expect(provider.type, '');
      expect(provider.logo, isNull);
    });

    test('toJson should produce correct output', () {
      const provider = AgentProvider(
        name: 'Claude',
        platform: 'cloud',
        type: 'llm',
        logo: 'logo.png',
      );

      final json = provider.toJson();

      expect(json['name'], 'Claude');
      expect(json['platform'], 'cloud');
      expect(json['type'], 'llm');
      expect(json['logo'], 'logo.png');
    });

    test('toJson should omit null logo', () {
      const provider = AgentProvider(
        name: 'Test',
        platform: 'local',
        type: 'tool',
      );

      final json = provider.toJson();
      expect(json.containsKey('logo'), false);
    });
  });

  group('AgentStatus Tests', () {
    test('fromJson should parse correctly', () {
      final json = {
        'state': 'online',
        'connected_at': 1700000000000,
        'last_heartbeat': 1700000001000,
      };

      final status = AgentStatus.fromJson(json);

      expect(status.state, 'online');
      expect(status.isOnline, true);
      expect(status.connectedAt, 1700000000000);
      expect(status.lastHeartbeat, 1700000001000);
    });

    test('fromJson should default to offline', () {
      final status = AgentStatus.fromJson({});

      expect(status.state, 'offline');
      expect(status.isOnline, false);
      expect(status.connectedAt, isNull);
      expect(status.lastHeartbeat, isNull);
    });

    test('toJson should produce correct output', () {
      const status = AgentStatus(
        state: 'online',
        connectedAt: 100,
        lastHeartbeat: 200,
      );

      final json = status.toJson();

      expect(json['state'], 'online');
      expect(json['connected_at'], 100);
      expect(json['last_heartbeat'], 200);
    });

    test('toJson should omit null timestamps', () {
      const status = AgentStatus(state: 'offline');
      final json = status.toJson();

      expect(json.containsKey('connected_at'), false);
      expect(json.containsKey('last_heartbeat'), false);
    });
  });

  group('Agent Model Tests', () {
    test('fromJson should create Agent from nested registration/status', () {
      final json = {
        'registration': {
          'agent_id': 'agent123',
          'name': 'TestAgent',
          'avatar': 'https://example.com/agent.png',
          'bio': 'A test agent',
          'type': 'assistant',
          'description': 'Desc',
          'provider': {
            'name': 'OpenAI',
            'platform': 'cloud',
            'type': 'llm',
          },
        },
        'status': {
          'state': 'online',
          'connected_at': 1700000000000,
        },
      };

      final agent = Agent.fromJson(json);

      expect(agent.id, 'agent123');
      expect(agent.name, 'TestAgent');
      expect(agent.avatar, 'https://example.com/agent.png');
      expect(agent.bio, 'A test agent');
      expect(agent.type, 'assistant');
      expect(agent.description, 'Desc');
      expect(agent.provider.name, 'OpenAI');
      expect(agent.status.state, 'online');
      expect(agent.status.isOnline, true);
    });

    test('fromJson should create Agent from flat structure', () {
      final json = {
        'id': 'agent456',
        'name': 'FlatAgent',
        'avatar': '🤖',
        'type': 'tool',
      };

      final agent = Agent.fromJson(json);

      expect(agent.id, 'agent456');
      expect(agent.name, 'FlatAgent');
      expect(agent.avatar, '🤖');
      expect(agent.type, 'tool');
      expect(agent.status.state, 'offline');
    });

    test('fromJson should handle missing fields gracefully', () {
      final agent = Agent.fromJson({});

      expect(agent.id, '');
      expect(agent.name, '');
      expect(agent.avatar, '🤖');
      expect(agent.status.isOnline, false);
    });

    test('toJson should produce correct output', () {
      final agent = Agent(
        id: 'agent123',
        name: 'TestAgent',
        avatar: 'https://example.com/agent.png',
        type: 'assistant',
        provider: const AgentProvider(
          name: 'OpenAI',
          platform: 'cloud',
          type: 'llm',
        ),
        status: const AgentStatus(state: 'online'),
      );

      final json = agent.toJson();

      expect(json['agent_id'], 'agent123');
      expect(json['name'], 'TestAgent');
      expect(json['avatar'], 'https://example.com/agent.png');
      expect(json['type'], 'assistant');
      expect(json['provider']['name'], 'OpenAI');
    });

    test('toJson should omit null optional fields', () {
      final agent = Agent(
        id: 'a',
        name: 'A',
        avatar: '🤖',
        provider: const AgentProvider(name: '', platform: '', type: ''),
        status: const AgentStatus(state: 'offline'),
      );

      final json = agent.toJson();

      // bio is always included (even when null)
      expect(json.containsKey('bio'), true);
      expect(json['bio'], isNull);
      expect(json.containsKey('type'), false);
      expect(json.containsKey('description'), false);
      expect(json.containsKey('model'), false);
      expect(json.containsKey('system_prompt'), false);
      expect(json.containsKey('temperature'), false);
      expect(json.containsKey('max_tokens'), false);
      expect(json.containsKey('capabilities'), false);
      expect(json.containsKey('metadata'), false);
    });

    test('Agent status should be checked via AgentStatus object', () {
      final onlineAgent = Agent(
        id: 'agent1',
        name: 'OnlineAgent',
        avatar: '🟢',
        provider: const AgentProvider(name: '', platform: '', type: ''),
        status: const AgentStatus(state: 'online'),
      );

      final offlineAgent = Agent(
        id: 'agent2',
        name: 'OfflineAgent',
        avatar: '🔴',
        provider: const AgentProvider(name: '', platform: '', type: ''),
        status: const AgentStatus(state: 'offline'),
      );

      expect(onlineAgent.status.isOnline, true);
      expect(offlineAgent.status.isOnline, false);
    });

    test('copyWith should update specified fields', () {
      final agent = Agent(
        id: 'agent1',
        name: 'Original',
        avatar: '🤖',
        provider: const AgentProvider(name: 'P', platform: 'p', type: 't'),
        status: const AgentStatus(state: 'offline'),
      );

      final updated = agent.copyWith(
        name: 'Updated',
        status: const AgentStatus(state: 'online'),
      );

      expect(updated.id, 'agent1');
      expect(updated.name, 'Updated');
      expect(updated.avatar, '🤖');
      expect(updated.status.isOnline, true);
    });
  });
}
