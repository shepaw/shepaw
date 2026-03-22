import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/token_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/remote_agent_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    // 初始化 FFI
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Remote Agent Creation Integration Test', () {
    late LocalDatabaseService dbService;
    late TokenService tokenService;
    late RemoteAgentService agentService;

    setUp(() async {
      // 创建服务实例
      dbService = LocalDatabaseService();
      tokenService = TokenService(dbService);
      agentService = RemoteAgentService(dbService, tokenService);

      // 确保数据库初始化
      await dbService.database;
    });

    test('Should create a remote agent with all fields', () async {
      // 创建助手
      final agent = await agentService.createAgent(
        name: '测试助手',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        endpoint: 'https://test.example.com/api',
        bio: '这是一个测试助手',
        avatar: '🤖',
        capabilities: ['chat', 'task'],
        metadata: {'version': '1.0.0'},
      );

      // 验证助手创建成功
      expect(agent, isNotNull);
      expect(agent.name, '测试助手');
      expect(agent.protocol, ProtocolType.acp);
      expect(agent.connectionType, ConnectionType.http);
      expect(agent.endpoint, 'https://test.example.com/api');
      expect(agent.bio, '这是一个测试助手');
      expect(agent.avatar, '🤖');
      expect(agent.status, AgentStatus.offline);
      expect(agent.capabilities, ['chat', 'task']);
      expect(agent.metadata['version'], '1.0.0');

      // 验证 Token
      expect(agent.token, isNotEmpty);
      expect(agent.token.length, 36); // UUID 格式
      expect(tokenService.validateToken(agent.token), true);

      print('✅ 助手创建成功！');
      print('   ID: ${agent.id}');
      print('   名称: ${agent.name}');
      print('   Token: ${agent.token}');
      print('   协议: ${agent.protocolName}');
      print('   连接方式: ${agent.connectionTypeName}');
      print('   状态: ${agent.statusText} ${agent.statusIcon}');
    });

    test('Should retrieve created agent from database', () async {
      // 创建助手
      final createdAgent = await agentService.createAgent(
        name: '查询测试助手',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.websocket,
        endpoint: 'wss://test.example.com/ws',
      );

      // 从数据库检索
      final retrievedAgent = await agentService.getAgentById(createdAgent.id);

      // 验证
      expect(retrievedAgent, isNotNull);
      expect(retrievedAgent!.id, createdAgent.id);
      expect(retrievedAgent.name, createdAgent.name);
      expect(retrievedAgent.token, createdAgent.token);
      expect(retrievedAgent.protocol, createdAgent.protocol);

      print('✅ 助手检索成功！');
      print('   从数据库成功读取助手信息');
    });

    test('Should list all agents', () async {
      // 创建多个助手
      await agentService.createAgent(
        name: '助手 1',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        endpoint: 'https://agent1.com',
      );

      await agentService.createAgent(
        name: '助手 2',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.websocket,
        endpoint: 'wss://agent2.com',
      );

      await agentService.createAgent(
        name: '助手 3',
        protocol: ProtocolType.custom,
        connectionType: ConnectionType.http,
        endpoint: 'https://agent3.com',
      );

      // 获取所有助手
      final allAgents = await agentService.getAllAgents();

      // 验证
      expect(allAgents.length, greaterThanOrEqualTo(3));

      print('✅ 助手列表获取成功！');
      print('   总共 ${allAgents.length} 个助手');
      for (final agent in allAgents.take(5)) {
        print('   - ${agent.name} (${agent.protocolName}/${agent.connectionTypeName}) ${agent.statusIcon}');
      }
    });

    test('Should verify token for created agent', () async {
      // 创建助手
      final agent = await agentService.createAgent(
        name: 'Token 验证测试',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        endpoint: 'https://test.com',
      );

      // 通过 Token 验证
      final verifiedAgent = await agentService.verifyToken(agent.token);

      // 验证
      expect(verifiedAgent, isNotNull);
      expect(verifiedAgent!.id, agent.id);
      expect(verifiedAgent.name, agent.name);

      print('✅ Token 验证成功！');
      print('   Token 可以正确验证并返回助手信息');
    });

    test('Should update agent status', () async {
      // 创建助手
      final agent = await agentService.createAgent(
        name: '状态更新测试',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        endpoint: 'https://test.com',
      );

      expect(agent.status, AgentStatus.offline);

      // 注册连接（应该更新为在线）
      final connectedAgent = await agentService.registerAgentConnection(
        agent.token,
        clientInfo: {'test': 'data'},
      );

      expect(connectedAgent, isNotNull);
      expect(connectedAgent!.status, AgentStatus.online);
      expect(connectedAgent.connectedAt, isNotNull);
      expect(connectedAgent.lastHeartbeat, isNotNull);

      print('✅ 状态更新成功！');
      print('   离线 → 在线: ${agent.statusIcon} → ${connectedAgent.statusIcon}');
    });

    test('Should delete agent', () async {
      // 创建助手
      final agent = await agentService.createAgent(
        name: '删除测试助手',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        endpoint: 'https://test.com',
      );

      // 确认存在
      var retrieved = await agentService.getAgentById(agent.id);
      expect(retrieved, isNotNull);

      // 删除
      await agentService.deleteAgent(agent.id);

      // 确认已删除
      retrieved = await agentService.getAgentById(agent.id);
      expect(retrieved, isNull);

      print('✅ 助手删除成功！');
    });

    test('Should get agent statistics', () async {
      // 创建一些助手
      await agentService.createAgent(
        name: 'ACP 助手 1',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        endpoint: 'https://test.com',
      );

      final acpAgent = await agentService.createAgent(
        name: 'ACP 助手',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.websocket,
        endpoint: 'wss://test.com',
      );

      // 让一个助手上线
      await agentService.registerAgentConnection(acpAgent.token);

      // 获取统计
      final stats = await agentService.getAgentStatistics();

      // 验证
      expect(stats['total'], greaterThanOrEqualTo(2));
      expect(stats['online'], greaterThanOrEqualTo(1));
      expect(stats['by_protocol'], isNotNull);
      expect(stats['by_connection_type'], isNotNull);

      print('✅ 统计信息获取成功！');
      print('   总计: ${stats['total']}');
      print('   在线: ${stats['online']}');
      print('   离线: ${stats['offline']}');
      print('   错误: ${stats['error']}');
      print('   协议分布: ${stats['by_protocol']}');
      print('   连接方式分布: ${stats['by_connection_type']}');
    });

    tearDown(() async {
      // 清理：删除测试数据
      await dbService.clearAllData();
    });
  });
}
