import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/agents/get_command.dart';
import 'package:shepaw/clis/shepaw/agents/agents_namespace.dart';
import 'package:shepaw/clis/shepaw/shepaw_cli.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/agent_memory_store_service.dart';
import 'package:shepaw/services/agent_profile_service.dart';
import 'package:shepaw/services/cli_namespace_registry.dart';
import 'package:shepaw/services/cognition_service.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await StorageTestHarness.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async {
        switch (call.method) {
          case 'getAll':
            return <String, Object?>{};
          case 'setString':
          case 'remove':
          case 'clear':
            return true;
          default:
            return null;
        }
      },
    );
    await LocalDatabaseService().database;
  });

  group('agents.get command', () {
    test('registered in agents namespace and CLI registry', () async {
      final nsHelp = await AgentsNamespace.instance.getHelpAsync();
      final commands = nsHelp['commands'] as Map<String, dynamic>;
      expect(commands.containsKey('get'), isTrue);

      expect(
        CliNamespaceRegistry.instance.allCommandIds,
        contains('context.agents.get'),
      );
    });

    test('getHelp documents --id and --sections', () {
      final help = GetCommand().getHelp();
      expect(help['command'], 'get');
      final flags = help['flags'] as Map<String, dynamic>;
      expect((flags['id'] as Map)['required'], isTrue);
      expect(flags.containsKey('sections'), isTrue);
      expect(help['sections'], AgentProfileService.sectionCatalog);
    });

    test('missing --id returns structured error without DB', () async {
      final result = await GetCommand().execute({});
      expect(result['error'], isNotNull);
      expect(result['error'] as String, contains('--id'));
    });

    test('default returns summary only (compact card)', () async {
      const agentId = 'test-agent-get-1';
      final db = LocalDatabaseService();
      await db.createRemoteAgent(RemoteAgent(
        id: agentId,
        name: 'Dart Helper',
        avatar: '🤖',
        bio: 'Self-described resume from bio field',
        token: 'tok',
        endpoint: 'http://localhost',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        status: AgentStatus.online,
        capabilities: ['coding', 'refactoring'],
        metadata: {
          'enabled_skills': ['git'],
        },
        createdAt: 0,
        updatedAt: 0,
      ));

      await CognitionService.instance.updateAgentSoul(
        agentId,
        '## Specialty\n擅长 Dart/Flutter 重构与单元测试编写',
      );

      final raw = await ShepawCLI.instance.execute({
        'namespace': 'context',
        'subcommand': 'agents.get',
        'flags': {'id': agentId},
      });
      final result = Map<String, dynamic>.from(jsonDecode(raw) as Map);

      expect(result['error'], isNull, reason: '${result['error']}');
      expect(result['id'], agentId);
      expect(result['name'], 'Dart Helper');
      expect(result['role'] as String, contains('Dart'));
      expect(result['experience_hint'], isNotNull);
      expect(result['sections_included'], ['summary']);
      expect(result.containsKey('bio'), isFalse);
      expect(result.containsKey('capabilities'), isFalse);
      expect(result['available_sections'], AgentProfileService.sectionCatalog);

      await db.deleteRemoteAgent(agentId);
      await AgentMemoryStoreService.forAgent(agentId).close();
    });

    test('--sections identity,capabilities returns selected slices', () async {
      const agentId = 'test-agent-get-2';
      final db = LocalDatabaseService();
      await db.createRemoteAgent(RemoteAgent(
        id: agentId,
        name: 'Bio Only',
        avatar: '🤖',
        bio: '擅长 Python 数据分析',
        token: 'tok',
        endpoint: 'http://localhost',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        status: AgentStatus.online,
        capabilities: ['python', 'pandas'],
        createdAt: 0,
        updatedAt: 0,
      ));

      final result = await GetCommand().execute({
        'id': agentId,
        'sections': 'identity,capabilities',
      });

      expect(result['error'], isNull);
      expect(result['bio'], '擅长 Python 数据分析');
      expect(result['capabilities'], ['python', 'pandas']);
      expect(result.containsKey('role'), isFalse);
      expect(
        (result['sections_included'] as List).contains('identity'),
        isTrue,
      );

      await db.deleteRemoteAgent(agentId);
    });

    test('empty soul uses bio in summary role via impression logic', () async {
      const agentId = 'test-agent-get-3';
      final db = LocalDatabaseService();
      await db.createRemoteAgent(RemoteAgent(
        id: agentId,
        name: 'Bio Only',
        avatar: '🤖',
        bio: '擅长 Python 数据分析',
        token: 'tok',
        endpoint: 'http://localhost',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        status: AgentStatus.online,
        capabilities: ['python', 'pandas'],
        createdAt: 0,
        updatedAt: 0,
      ));

      final result = await GetCommand().execute({'id': agentId});

      expect(result['role'], '擅长 Python 数据分析');
      expect(result['sections_included'], ['summary']);

      await db.deleteRemoteAgent(agentId);
    });
  });
}
