import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/clis/cli_command_allowlist.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/cli_execution_gate.dart';
import 'package:shepaw/services/cli_namespace_registry.dart';

import '../storage/test_harness.dart';

RemoteAgent _agentWith(Map<String, dynamic> metadata) => RemoteAgent(
      id: 'a1',
      name: 'A',
      token: 't',
      endpoint: 'ws://x',
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.websocket,
      createdAt: 0,
      updatedAt: 0,
      metadata: metadata,
    );

/// P0-2 回归：命令选择器曾有两个 bug。
///
/// 1. `allCommandIds` 缺 os/store/workflow ⇒ 取消勾选任意一条后永远凑不满
///    「全选」，这三个命名空间被静默写掉。
/// 2. 「全不选」产出 `{}`，而持久化层把空列表解释为「全部放行」⇒ 点
///    「全不选」等于放行一切 —— 误操作方向是最坏的那个。
///
/// 修法是让持久化格式三态化（key 缺失 / `[]` / 非空），让两个状态在类型上
/// 不可混淆。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    SharedPreferences.setMockInitialValues({});
  });

  group('cliSelectionToAllowlist', () {
    final all = CliNamespaceRegistry.instance.allCommandIds.toSet();

    test('全选 → null（不受限），而不是空集', () {
      expect(cliSelectionToAllowlist(selected: all, allCommandIds: all), isNull);
    });

    test('全不选 → {}（全禁），与「不受限」不同', () {
      final result =
          cliSelectionToAllowlist(selected: const {}, allCommandIds: all);
      expect(result, isNotNull);
      expect(result, isEmpty);
      expect(result, isNot(cliSelectionToAllowlist(
        selected: all,
        allCommandIds: all,
      )));
    });

    test('取消勾选一条之后，os / store / workflow 仍在结果里', () {
      // 这条直接钉死 P0-2 bug 1：旧实现下 allIds 缺这三个命名空间，
      // 于是「取消任意一条」会让它们整批消失。
      final dropped = all.firstWhere((id) => id.startsWith('os.'));
      final selected = Set<String>.from(all)..remove(dropped);
      final result =
          cliSelectionToAllowlist(selected: selected, allCommandIds: all)!;

      expect(result, isNot(isEmpty));
      expect(
        result.map((id) => id.split('.').first).toSet(),
        containsAll(['os', 'store', 'workflow']),
      );
      expect(result, isNot(contains(dropped)));
    });

    test('部分选中原样返回', () {
      expect(
        cliSelectionToAllowlist(
          selected: const {'store.read'},
          allCommandIds: all,
        ),
        {'store.read'},
      );
    });
  });

  group('RemoteAgent.enabledCliCommands 三态', () {
    test('key 缺失 → null（不受限）', () {
      final agent = _agentWith(const {});
      expect(agent.enabledCliCommands, isNull);
      expect(agent.hasEnabledCliCommands, isFalse);
    });

    test('[] → {}（全禁），与 key 缺失可区分', () {
      final agent = _agentWith(const {'enabled_cli_commands': <String>[]});
      expect(agent.enabledCliCommands, isNotNull);
      expect(agent.enabledCliCommands, isEmpty);
      expect(agent.hasEnabledCliCommands, isFalse);
    });

    test('非空 → 该集合', () {
      final agent = _agentWith(const {
        'enabled_cli_commands': ['store.read'],
      });
      expect(agent.enabledCliCommands, {'store.read'});
      expect(agent.hasEnabledCliCommands, isTrue);
    });
  });

  group('存量配置不被误锁', () {
    // 唯一的「能把用户锁死」的风险点：P0-4 让 `{}` 变成全禁之后，如果持久化
    // 层还把「key 缺失」读成 `{}`，所有存量 agent（metadata 里根本没有
    // enabled_cli_commands）会瞬间失去全部 CLI 能力。
    test('metadata 无 key 的 agent 仍然能调 CLI', () async {
      final agent = _agentWith(const {});
      final raw = await CliExecutionGate.instance.execute(
        args: {'namespace': 'store', 'subcommand': 'read', 'flags': {}},
        agentId: agent.id,
        enabledCliCommands: agent.enabledCliCommands,
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(result['error']?.toString() ?? '', isNot(contains('not allowed')));
    });

    test('metadata 为 [] 的 agent 被拒绝', () async {
      final agent = _agentWith(const {'enabled_cli_commands': <String>[]});
      final raw = await CliExecutionGate.instance.execute(
        args: {'namespace': 'store', 'subcommand': 'read', 'flags': {}},
        agentId: agent.id,
        enabledCliCommands: agent.enabledCliCommands,
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(result['error'], contains('not allowed for this agent'));
    });
  });
}
