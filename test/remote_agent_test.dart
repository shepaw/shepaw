import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/token_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/remote_agent_service.dart';

void main() {
  group('RemoteAgent Model Tests', () {
    test('RemoteAgent should be created with correct fields', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final agent = RemoteAgent(
        id: 'test-id',
        name: 'Test Agent',
        avatar: '🤖',
        bio: 'Test bio',
        token: 'test-token',
        endpoint: 'https://example.com',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        status: AgentStatus.offline,
        capabilities: ['chat', 'task'],
        metadata: {'key': 'value'},
        createdAt: now,
        updatedAt: now,
      );

      expect(agent.id, 'test-id');
      expect(agent.name, 'Test Agent');
      expect(agent.protocol, ProtocolType.acp);
      expect(agent.status, AgentStatus.offline);
      expect(agent.isOffline, true);
      expect(agent.isOnline, false);
    });

    test('RemoteAgent should serialize to JSON correctly', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final agent = RemoteAgent(
        id: 'test-id',
        name: 'Test Agent',
        token: 'test-token',
        endpoint: 'https://example.com',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        createdAt: now,
        updatedAt: now,
      );

      final json = agent.toJson();

      expect(json['id'], 'test-id');
      expect(json['name'], 'Test Agent');
      expect(json['protocol'], 'acp');
      expect(json['connection_type'], 'http');
    });

    test('RemoteAgent should deserialize from JSON correctly', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final json = {
        'id': 'test-id',
        'name': 'Test Agent',
        'avatar': '🤖',
        'bio': 'Test bio',
        'token': 'test-token',
        'endpoint': 'https://example.com',
        'protocol': 'acp',
        'connection_type': 'http',
        'status': 'offline',
        'last_heartbeat': null,
        'connected_at': null,
        'capabilities': '[]',
        'metadata': '{}',
        'created_at': now,
        'updated_at': now,
      };

      final agent = RemoteAgent.fromJson(json);

      expect(agent.id, 'test-id');
      expect(agent.name, 'Test Agent');
      expect(agent.protocol, ProtocolType.acp);
      expect(agent.connectionType, ConnectionType.http);
    });

    test('RemoteAgent copyWith should work correctly', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final agent = RemoteAgent(
        id: 'test-id',
        name: 'Test Agent',
        token: 'test-token',
        endpoint: 'https://example.com',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        status: AgentStatus.offline,
        createdAt: now,
        updatedAt: now,
      );

      final updated = agent.copyWith(
        name: 'Updated Agent',
        status: AgentStatus.online,
      );

      expect(updated.id, 'test-id');
      expect(updated.name, 'Updated Agent');
      expect(updated.status, AgentStatus.online);
      expect(updated.endpoint, 'https://example.com');
    });

    test('Protocol and ConnectionType enums should work', () {
      expect(ProtocolType.acp.toJson(), 'acp');
      expect(ProtocolType.fromJson('acp'), ProtocolType.acp);

      expect(ConnectionType.websocket.toJson(), 'websocket');
      expect(ConnectionType.fromJson('http'), ConnectionType.http);

      expect(AgentStatus.online.toJson(), 'online');
      expect(AgentStatus.fromJson('offline'), AgentStatus.offline);
    });
  });

  group('TokenService Tests', () {
    test('TokenService should generate valid UUID tokens', () async {
      final dbService = LocalDatabaseService();
      final tokenService = TokenService(dbService);

      final token = tokenService.generateToken();

      expect(token, isNotNull);
      expect(token.length, 36); // UUID v4 format
      expect(tokenService.validateToken(token), true);
    });

    test('TokenService should validate token format', () {
      final dbService = LocalDatabaseService();
      final tokenService = TokenService(dbService);

      expect(tokenService.validateToken('invalid'), false);
      expect(tokenService.validateToken(''), false);
      expect(
        tokenService.validateToken('550e8400-e29b-41d4-a716-446655440000'),
        true,
      );
    });
  });

  group('Protocol and Status Display Tests', () {
    test('RemoteAgent should return correct display names', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final agent = RemoteAgent(
        id: 'test',
        name: 'Test',
        token: 'token',
        endpoint: 'http://test.com',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.websocket,
        status: AgentStatus.online,
        createdAt: now,
        updatedAt: now,
      );

      expect(agent.protocolName, 'ACP');
      expect(agent.connectionTypeName, 'WebSocket');
      expect(agent.statusText, '在线');
      expect(agent.statusIcon, '🟢');
    });

    test('RemoteAgent should return correct status icons', () {
      final now = DateTime.now().millisecondsSinceEpoch;

      final online = RemoteAgent(
        id: 'test',
        name: 'Test',
        token: 'token',
        endpoint: 'http://test.com',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        status: AgentStatus.online,
        createdAt: now,
        updatedAt: now,
      );
      expect(online.statusIcon, '🟢');

      final offline = online.copyWith(status: AgentStatus.offline);
      expect(offline.statusIcon, '🟡');

      final error = online.copyWith(status: AgentStatus.error);
      expect(error.statusIcon, '🔴');
    });
  });
}
