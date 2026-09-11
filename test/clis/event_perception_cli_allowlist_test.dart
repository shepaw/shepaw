import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/chat/chat_agent_scope.dart';
import 'package:shepaw/clis/shepaw/shepaw_cli.dart';
import 'package:shepaw/services/she_service.dart';

import '../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
  });

  test('cliAllowlist blocks non-whitelisted commands in scoped zone', () async {
    final result = await ChatAgentScope.runScoped<Map<String, dynamic>>(
      agentId: SheService.sheId,
      cliAllowlist: const {'peer.accept', 'peer.reject', 'peer.status'},
      body: () async {
        final raw = await ShepawCLI.instance.execute({
          'namespace': 'peer',
          'subcommand': 'list',
          'flags': {},
        });
        return jsonDecode(raw) as Map<String, dynamic>;
      },
    );

    expect(result['error'], contains('not allowed'));
    expect(result['allowed_commands'], contains('peer.accept'));
  });

  test('cliAllowlist allows whitelisted command through gate', () async {
    final result = await ChatAgentScope.runScoped<Map<String, dynamic>>(
      agentId: SheService.sheId,
      cliAllowlist: const {'peer.status'},
      body: () async {
        final raw = await ShepawCLI.instance.execute({
          'namespace': 'peer',
          'subcommand': 'status',
          'flags': {},
        });
        return jsonDecode(raw) as Map<String, dynamic>;
      },
    );

    final err = result['error']?.toString() ?? '';
    expect(err.contains('not allowed'), isFalse);
  });

  test('cliAllowlist namespace entry allows descendant commands', () async {
    final result = await ChatAgentScope.runScoped<Map<String, dynamic>>(
      agentId: SheService.sheId,
      cliAllowlist: const {'peer'},
      body: () async {
        final raw = await ShepawCLI.instance.execute({
          'namespace': 'peer',
          'subcommand': 'list',
          'flags': {},
        });
        return jsonDecode(raw) as Map<String, dynamic>;
      },
    );

    final err = result['error']?.toString() ?? '';
    expect(err.contains('not allowed'), isFalse);
  });

  /// P0-5 回归：`help` 与未知 namespace 的短路曾经在权限检查之前，
  /// 会把**全部**命名空间及其描述回吐给任何调用者——而
  /// `cliFilterNamespaces` 在交集为空时又故意回退到 `help`，于是「被限到
  /// 什么都没有」的 agent 恰好拿到唯一会泄露全量列表的那个命名空间。
  group('help payload follows the zone allowlist', () {
    Future<Map<String, dynamic>> call({
      required String namespace,
      required Set<String> allowlist,
    }) async {
      return ChatAgentScope.runScoped<Map<String, dynamic>>(
        agentId: SheService.sheId,
        cliAllowlist: allowlist,
        body: () async {
          final raw = await ShepawCLI.instance.execute({
            'namespace': namespace,
            'subcommand': '',
            'flags': {},
          });
          return jsonDecode(raw) as Map<String, dynamic>;
        },
      );
    }

    test('help is still callable when allowlisted to almost nothing', () async {
      final result = await call(
        namespace: 'help',
        allowlist: const {'peer.accept'},
      );
      expect(result['cli'], isNotNull);
    });

    test('help does not leak namespaces outside the allowlist', () async {
      final result = await call(
        namespace: 'help',
        allowlist: const {'peer.accept'},
      );
      final namespaces = (result['namespaces'] as Map).keys.toSet();
      expect(namespaces, contains('peer'));
      expect(namespaces, isNot(contains('os')));
      expect(namespaces, isNot(contains('store')));
      expect(namespaces, isNot(contains('workflow')));
      expect(namespaces, isNot(contains('context')));
    });

    test('unknown namespace available list is filtered too', () async {
      final result = await call(
        namespace: 'nope',
        allowlist: const {'peer.accept'},
      );
      expect(result['error'], contains('Unknown namespace'));
      final available = (result['available'] as List).cast<String>();
      expect(available, ['peer']);
    });

    test('unrestricted zone still sees every namespace', () async {
      final result = await ChatAgentScope.runScoped<Map<String, dynamic>>(
        agentId: SheService.sheId,
        body: () async {
          final raw = await ShepawCLI.instance.execute({
            'namespace': 'help',
            'subcommand': '',
            'flags': {},
          });
          return jsonDecode(raw) as Map<String, dynamic>;
        },
      );
      final namespaces = (result['namespaces'] as Map).keys.toSet();
      expect(namespaces, containsAll(['os', 'store', 'workflow', 'peer']));
    });
  });

  test('null cliAllowlist does not restrict commands', () async {
    final result = await ChatAgentScope.runScoped<Map<String, dynamic>>(
      agentId: SheService.sheId,
      body: () async {
        final raw = await ShepawCLI.instance.execute({
          'namespace': 'peer',
          'subcommand': 'list',
          'flags': {},
        });
        return jsonDecode(raw) as Map<String, dynamic>;
      },
    );

    final err = result['error']?.toString() ?? '';
    expect(err.contains('not allowed'), isFalse);
  });
}
