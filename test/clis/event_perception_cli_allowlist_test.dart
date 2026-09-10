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
    expect(err.contains('not allowed during event perception'), isFalse);
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
    expect(err.contains('not allowed during event perception'), isFalse);
  });
}
