import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/token_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/remote_agent_service.dart';
import 'package:shepaw/screens/add_remote_agent_screen.dart';
import 'package:shepaw/screens/remote_agent_list_screen.dart';

void main() {
  testWidgets('Add Remote Agent Screen UI Test', (WidgetTester tester) async {
    // 构建添加助手界面
    await tester.pumpWidget(
      const MaterialApp(
        home: AddRemoteAgentScreen(),
      ),
    );

    // 等待界面渲染
    await tester.pumpAndSettle();

    // 验证界面元素存在
    expect(find.text('添加远端助手'), findsOneWidget);
    expect(find.text('助手名称'), findsOneWidget);
    expect(find.text('协议类型'), findsOneWidget);
    expect(find.text('连接类型'), findsOneWidget);
    expect(find.text('创建助手'), findsOneWidget);

    print('✅ 添加助手界面渲染正常');
  });

  testWidgets('Remote Agent List Screen UI Test', (WidgetTester tester) async {
    // 构建助手列表界面
    await tester.pumpWidget(
      const MaterialApp(
        home: RemoteAgentListScreen(),
      ),
    );

    // 等待界面渲染
    await tester.pumpAndSettle();

    // 验证界面元素
    expect(find.text('远端助手'), findsOneWidget);
    expect(find.text('添加助手'), findsOneWidget);

    print('✅ 助手列表界面渲染正常');
  });

  group('Service Layer Integration Tests', () {
    test('Create agent workflow', () async {
      // 模拟创建助手的完整流程
      final dbService = LocalDatabaseService();
      final tokenService = TokenService(dbService);
      final agentService = RemoteAgentService(dbService, tokenService);

      try {
        // 1. 创建助手
        final agent = await agentService.createAgent(
          name: '集成测试助手',
          protocol: ProtocolType.acp,
          connectionType: ConnectionType.http,
          endpoint: 'https://test.example.com',
          bio: '用于集成测试',
          avatar: '🧪',
        );

        print('✅ 步骤 1: 助手创建成功');
        print('   ID: ${agent.id}');
        print('   名称: ${agent.name}');
        print('   Token: ${agent.token}');

        // 2. 验证 Token 格式
        expect(tokenService.validateToken(agent.token), isTrue);
        print('✅ 步骤 2: Token 格式验证通过');

        // 3. 通过 Token 查询助手
        final verifiedAgent = await agentService.verifyToken(agent.token);
        expect(verifiedAgent, isNotNull);
        expect(verifiedAgent!.id, agent.id);
        print('✅ 步骤 3: Token 验证成功，助手信息匹配');

        // 4. 通过 ID 查询助手
        final retrievedAgent = await agentService.getAgentById(agent.id);
        expect(retrievedAgent, isNotNull);
        expect(retrievedAgent!.name, '集成测试助手');
        print('✅ 步骤 4: 数据库查询成功');

        // 5. 列出所有助手
        final allAgents = await agentService.getAllAgents();
        expect(allAgents.any((a) => a.id == agent.id), isTrue);
        print('✅ 步骤 5: 助手出现在列表中（共 ${allAgents.length} 个）');

        // 6. 模拟连接注册
        final connectedAgent = await agentService.registerAgentConnection(
          agent.token,
          clientInfo: {'test': 'integration'},
        );
        expect(connectedAgent, isNotNull);
        expect(connectedAgent!.status, AgentStatus.online);
        print('✅ 步骤 6: 连接注册成功，状态变为在线 ${connectedAgent.statusIcon}');

        // 7. 更新心跳
        await agentService.updateHeartbeat(agent.id);
        final afterHeartbeat = await agentService.getAgentById(agent.id);
        expect(afterHeartbeat!.lastHeartbeat, isNotNull);
        print('✅ 步骤 7: 心跳更新成功');

        // 8. 获取统计信息
        final stats = await agentService.getAgentStatistics();
        expect(stats['total'], greaterThan(0));
        expect(stats['online'], greaterThan(0));
        print('✅ 步骤 8: 统计信息获取成功');
        print('   总计: ${stats['total']}, 在线: ${stats['online']}');

        // 9. 断开连接
        await agentService.disconnectAgent(agent.id);
        final disconnectedAgent = await agentService.getAgentById(agent.id);
        expect(disconnectedAgent!.status, AgentStatus.offline);
        print('✅ 步骤 9: 断开连接成功，状态变为离线 ${disconnectedAgent.statusIcon}');

        // 10. 删除助手
        await agentService.deleteAgent(agent.id);
        final deletedAgent = await agentService.getAgentById(agent.id);
        expect(deletedAgent, isNull);
        print('✅ 步骤 10: 助手删除成功');

        print('\n🎉 完整的创建助手工作流测试通过！');
        print('   所有 10 个步骤都成功执行');
      } catch (e) {
        print('❌ 测试失败: $e');
        rethrow;
      }
    });

    test('Multiple agents management', () async {
      final dbService = LocalDatabaseService();
      final tokenService = TokenService(dbService);
      final agentService = RemoteAgentService(dbService, tokenService);

      try {
        // 创建多个不同配置的助手
        final agents = <RemoteAgent>[];

        // ACP HTTP 助手
        agents.add(await agentService.createAgent(
          name: 'ACP HTTP 助手',
          protocol: ProtocolType.acp,
          connectionType: ConnectionType.http,
          endpoint: 'https://acp1.example.com',
        ));

        // ACP WebSocket 助手
        agents.add(await agentService.createAgent(
          name: 'ACP WebSocket 助手',
          protocol: ProtocolType.acp,
          connectionType: ConnectionType.websocket,
          endpoint: 'wss://acp.example.com',
        ));

        // 自定义协议助手
        agents.add(await agentService.createAgent(
          name: '自定义协议助手',
          protocol: ProtocolType.custom,
          connectionType: ConnectionType.http,
          endpoint: 'https://custom.example.com',
        ));

        print('✅ 创建了 ${agents.length} 个不同配置的助手');

        // 让部分助手上线
        await agentService.registerAgentConnection(agents[0].token);
        await agentService.registerAgentConnection(agents[1].token);

        // 获取统计
        final stats = await agentService.getAgentStatistics();
        print('✅ 统计信息:');
        print('   总计: ${stats['total']}');
        print('   在线: ${stats['online']}');
        print('   离线: ${stats['offline']}');
        print('   ACP: ${stats['by_protocol']['acp']}');
        print('   ACP: ${stats['by_protocol']['acp']}');
        print('   自定义: ${stats['by_protocol']['custom']}');

        // 清理
        for (final agent in agents) {
          await agentService.deleteAgent(agent.id);
        }

        print('✅ 多助手管理测试通过！');
      } catch (e) {
        print('❌ 测试失败: $e');
        rethrow;
      }
    });
  });
}
