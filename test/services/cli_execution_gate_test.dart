import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/clis/cli_command_allowlist.dart';
import 'package:shepaw/clis/shepaw/os/os_executor.dart' as os_exec;
import 'package:shepaw/models/peer_boundary_config.dart';
import 'package:shepaw/services/cli_execution_gate.dart';
import 'package:shepaw/services/she_service.dart';

import '../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    SharedPreferences.setMockInitialValues({});
  });

  group('cliCommandAllowed', () {
    test('namespace entry allows descendants', () {
      expect(cliCommandAllowed({'store', 'help'}, 'store.write'), isTrue);
      expect(cliCommandAllowed({'store', 'help'}, 'help'), isTrue);
      expect(cliCommandAllowed({'store', 'help'}, 'os.command.exec'), isFalse);
    });

    test('full command id still matches exactly', () {
      expect(cliCommandAllowed({'peer.status'}, 'peer.status'), isTrue);
      expect(cliCommandAllowed({'peer.status'}, 'peer.list'), isFalse);
    });
  });

  group('CliExecutionGate', () {
    test('enabledCliCommands denies unlisted command', () async {
      final raw = await CliExecutionGate.instance.execute(
        args: {
          'namespace': 'peer',
          'subcommand': 'list',
          'flags': {},
        },
        agentId: 'agent-other',
        enabledCliCommands: const {'peer.status'},
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(result['error'], contains('not allowed for this agent'));
      expect(result['command'], 'peer.list');
    });

    test('enabledCliCommands namespace entry allows descendant', () async {
      final raw = await CliExecutionGate.instance.execute(
        args: {
          'namespace': 'peer',
          'subcommand': 'status',
          'flags': {},
        },
        agentId: SheService.sheId,
        enabledCliCommands: const {'peer'},
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(result['error']?.toString() ?? '', isNot(contains('not allowed')));
    });

    test('extraAllowlist blocks group-member os calls', () async {
      final raw = await CliExecutionGate.instance.execute(
        args: {
          'namespace': 'os',
          'subcommand': 'command.exec',
          'flags': {'cmd': 'ls'},
        },
        agentId: 'agent-member',
        extraAllowlist: kGroupMemberCliAllowlist,
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(result['error'], contains('not allowed'));
      expect(result['allowed_commands'], contains('store'));
    });

    test('peer boundary blocks os.*', () async {
      final raw = await CliExecutionGate.instance.execute(
        args: {
          'namespace': 'os',
          'subcommand': 'command.exec',
          'flags': {'cmd': 'ls'},
        },
        agentId: 'agent-other',
        peerBoundary: PeerBoundaryConfig.defaults,
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(result['peer_boundary'], isTrue);
    });

    test('unsafe os without confirmation callback is denied', () async {
      final raw = await CliExecutionGate.instance.execute(
        args: {
          'namespace': 'os',
          'subcommand': 'command.exec',
          'flags': {'cmd': 'rm -rf /tmp/x'},
        },
        agentId: SheService.sheId,
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(result['error'], contains('denied by the user'));
    });

    test('unsafe os proceeds when confirmation returns true', () async {
      var asked = false;
      final raw = await CliExecutionGate.instance.execute(
        args: {
          'namespace': 'help',
          'subcommand': '',
          'flags': {},
        },
        agentId: SheService.sheId,
        onOsConfirmation: (tool, flags, risk) async {
          asked = true;
          expect(risk, isNot(os_exec.RiskLevel.safe));
          return true;
        },
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(asked, isFalse); // help is not os
      expect(result['cli'], isNotNull);
    });
  });
}
