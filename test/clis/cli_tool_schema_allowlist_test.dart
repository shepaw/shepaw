import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/cli_command_allowlist.dart';
import 'package:shepaw/clis/shepaw/shepaw_cli.dart';
import 'package:shepaw/services/cli_execution_gate.dart';

List<String> _namespaceEnum(Map<String, dynamic> tool) {
  final fn = tool['function'] as Map<String, dynamic>?;
  final params = (fn?['parameters'] ?? tool['input_schema']) as Map;
  final ns = (params['properties'] as Map)['namespace'] as Map;
  return List<String>.from(ns['enum'] as List);
}

String _description(Map<String, dynamic> tool) {
  final fn = tool['function'] as Map<String, dynamic>?;
  return (fn?['description'] ?? tool['description']) as String;
}

void main() {
  group('cliFilterNamespaces', () {
    const all = ['store', 'help', 'os', 'peer'];

    test('unrestricted keeps every namespace', () {
      expect(cliFilterNamespaces(all), all);
    });

    test('per-agent namespace entry keeps that namespace', () {
      expect(
        cliFilterNamespaces(all, enabledCliCommands: const {'store'}),
        ['store'],
      );
    });

    test('full command id still advertises its namespace', () {
      expect(
        cliFilterNamespaces(all, enabledCliCommands: const {'peer.status'}),
        ['peer'],
      );
    });

    test('extra allowlist intersects with per-agent', () {
      expect(
        cliFilterNamespaces(
          all,
          enabledCliCommands: const {'store', 'os'},
          extraAllowlist: kGroupMemberCliAllowlist,
        ),
        ['store'],
      );
    });

    test('empty intersection falls back to help', () {
      expect(
        cliFilterNamespaces(
          all,
          enabledCliCommands: const {'os'},
          extraAllowlist: kGroupMemberCliAllowlist,
        ),
        ['help'],
      );
    });
  });

  group('ShepawCLI tool schema', () {
    test('openAITool enum is unfiltered by default', () {
      final ns = _namespaceEnum(ShepawCLI.instance.openAITool());
      expect(ns, containsAll(['store', 'help', 'os']));
    });

    test('openAITool enum follows enabledCliCommands', () {
      final tool = ShepawCLI.instance.openAITool(
        enabledCliCommands: const {'store.write', 'help'},
      );
      expect(_namespaceEnum(tool), ['store', 'help']);
      expect(_description(tool), contains('per-agent: help, store.write'));
    });

    test('claudeTool extraAllowlist trims to store and help', () {
      final tool = ShepawCLI.instance.claudeTool(
        extraAllowlist: kGroupMemberCliAllowlist,
      );
      expect(_namespaceEnum(tool), ['store', 'help']);
      expect(_description(tool), contains('role: help, store'));
    });
  });
}
