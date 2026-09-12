import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/clis/cli_command_allowlist.dart';
import 'package:shepaw/clis/shepaw/os/os_executor.dart' as os_exec;
import 'package:shepaw/models/peer_boundary_config.dart';
import 'package:shepaw/services/cli_approval_coordinator.dart';
import 'package:shepaw/services/cli_execution_gate.dart';
import 'package:shepaw/services/she_service.dart';

import '../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    SharedPreferences.setMockInitialValues({});
  });

  setUp(CliApprovalCoordinator.instance.resetForTest);

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

  group('cliCommandApprovalExempt', () {
    test('help and everyday store I/O skip approval', () {
      expect(cliCommandApprovalExempt('help'), isTrue);
      expect(cliCommandApprovalExempt('help.foo'), isTrue);
      expect(cliCommandApprovalExempt('store.read'), isTrue);
      expect(cliCommandApprovalExempt('store.list'), isTrue);
      expect(cliCommandApprovalExempt('store.search'), isTrue);
      expect(cliCommandApprovalExempt('store.write'), isTrue);
      expect(cliCommandApprovalExempt('store.events'), isTrue);
      expect(cliCommandApprovalExempt('store.spaces'), isTrue);
      expect(cliCommandApprovalExempt('store.declare'), isFalse);
      expect(
        cliCommandApprovalExempt(
          'store.write',
          flags: const {'file': '/tmp/shot.png'},
        ),
        isFalse,
      );
      expect(cliCommandApprovalExempt('peer.list'), isFalse);
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

    test('requireApproval denies without confirmation', () async {
      final raw = await CliExecutionGate.instance.execute(
        args: {
          'namespace': 'peer',
          'subcommand': 'list',
          'flags': {},
        },
        agentId: 'agent-other',
        requireApproval: true,
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(result['approval_denied'], isTrue);
      expect(result['command'], 'peer.list');
    });

    test('requireApproval skips store.write without --file', () async {
      var asked = false;
      final raw = await CliExecutionGate.instance.execute(
        args: {
          'namespace': 'store',
          'subcommand': 'write',
          'flags': {},
        },
        agentId: 'agent-other',
        requireApproval: true,
        onOsConfirmation: (tool, flags, risk) async {
          asked = true;
          return true;
        },
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(asked, isFalse);
      expect(result['approval_denied'], isNot(isTrue));
      expect(result['error'], contains('missing --filename'));
    });

    test('requireApproval still asks store.write --file', () async {
      var asked = false;
      final raw = await CliExecutionGate.instance.execute(
        args: {
          'namespace': 'store',
          'subcommand': 'write',
          'flags': {'file': '/tmp/shot.png', 'filename': 'shot.png'},
        },
        agentId: 'agent-other',
        requireApproval: true,
        onOsConfirmation: (tool, flags, risk) async {
          asked = true;
          return false;
        },
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(asked, isTrue);
      expect(result['approval_denied'], isTrue);
    });

    test('session grant skips a later confirmation', () async {
      var asked = 0;
      CliApprovalCoordinator.instance.grantForSession('peer.list');
      final raw = await CliExecutionGate.instance.execute(
        args: {
          'namespace': 'peer',
          'subcommand': 'list',
          'flags': {},
        },
        agentId: 'agent-other',
        requireApproval: true,
        onOsConfirmation: (tool, flags, risk) async {
          asked += 1;
          return true;
        },
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(asked, 0);
      expect(result['approval_denied'], isNot(isTrue));
    });

    test('requireApproval proceeds when confirmation returns true', () async {
      var asked = false;
      final raw = await CliExecutionGate.instance.execute(
        args: {
          'namespace': 'peer',
          'subcommand': 'list',
          'flags': {},
        },
        agentId: SheService.sheId,
        requireApproval: true,
        onOsConfirmation: (tool, flags, risk) async {
          asked = true;
          expect(tool, 'peer.list');
          return true;
        },
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(asked, isTrue);
      expect(result['approval_denied'], isNot(isTrue));
      expect(result['error']?.toString() ?? '', isNot(contains('denied')));
    });

    test('coordinator handler is used when callback is omitted', () async {
      var asked = false;
      CliApprovalCoordinator.instance.register((tool, flags, risk) async {
        asked = true;
        return true;
      });
      final raw = await CliExecutionGate.instance.execute(
        args: {
          'namespace': 'peer',
          'subcommand': 'list',
          'flags': {},
        },
        agentId: 'agent-other',
        requireApproval: true,
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(asked, isTrue);
      expect(result['approval_denied'], isNot(isTrue));
    });
  });

  /// `help` 不受 allowlist 限制，但它回答的是「你能看见哪些命名空间」。
  ///
  /// 这两件事必须同时成立才安全：只豁免不转发，受限 agent 会从 help 里读到
  /// 自己无权使用的全部命名空间；只转发不豁免，`cliFilterNamespaces` 在交集
  /// 为空时回退的 `['help']` 就成了永远调不通的假承诺。
  group('help 豁免与 allowlist 转发', () {
    /// 从 help 结果里取出模型能看到的命名空间名。
    Future<Set<String>> helpNamespaces({
      Set<String>? enabledCliCommands,
      Set<String>? extraAllowlist,
      bool isUiOperation = false,
      bool expectError = false,
    }) async {
      final raw = await CliExecutionGate.instance.execute(
        args: {'namespace': 'help', 'subcommand': '', 'flags': {}},
        agentId: 'agent-other',
        isUiOperation: isUiOperation,
        enabledCliCommands: enabledCliCommands,
        extraAllowlist: extraAllowlist,
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(result['error'], expectError ? isNotNull : isNull);
      return ((result['namespaces'] as Map?) ?? const {}).keys
          .cast<String>()
          .toSet();
    }

    test('per-agent 白名单：help 可调，但只列出被放行的命名空间', () async {
      // 旧行为下这就漏了：Gate 只转发 extraAllowlist，help 拿到的 allowlist
      // 是 null → 13 个命名空间全吐。
      final visible = await helpNamespaces(
        enabledCliCommands: const {'store.read'},
      );
      expect(visible, {'store'});
      for (final leaked in ['os', 'workflow', 'peer', 'vision', 'models']) {
        expect(visible, isNot(contains(leaked)), reason: '$leaked 泄漏了');
      }
    });

    test('per-agent 白名单：具体命令收敛到它所在的命名空间', () async {
      expect(
        await helpNamespaces(enabledCliCommands: const {'os.command.exec'}),
        {'os'},
      );
      expect(
        await helpNamespaces(
          enabledCliCommands: const {'context.profile.query'},
        ),
        {'context'},
      );
    });

    test('全禁（{}）：help 仍可调，但一个命名空间都不列', () async {
      // cliFilterNamespaces 的空交集回退成 ['help'] —— 到这里才真正自洽：
      // 模型有个能调用的命令，而这个命令什么也不告诉它。
      expect(await helpNamespaces(enabledCliCommands: const {}), isEmpty);
    });

    test('群成员轴：两张白名单取交集', () async {
      // extraAllowlist 之前就在转发，这里钉死它和新加的 per-agent 轴是取交
      // 而不是互相覆盖。
      expect(
        await helpNamespaces(
          enabledCliCommands: const {'store.read', 'os.command.exec'},
          extraAllowlist: kGroupMemberCliAllowlist,
        ),
        {'store'},
      );
      expect(
        await helpNamespaces(extraAllowlist: kGroupMemberCliAllowlist),
        {'store'},
      );
    });

    test('不带任何白名单：help 列出全部（默认不受限）', () async {
      final visible = await helpNamespaces();
      expect(visible, containsAll(['os', 'store', 'workflow']));
    });

    test('UI 操作不受 per-agent 白名单约束', () async {
      // isUiOperation 的语义是「用户自己在界面上点的」，不能被 agent 配置
      // 反向锁住。
      expect(
        await helpNamespaces(
          enabledCliCommands: const {'store.read'},
          isUiOperation: true,
        ),
        containsAll(['os', 'store', 'workflow']),
      );
    });

    test('豁免只覆盖 help 本身，别的命令照旧被拒', () async {
      final raw = await CliExecutionGate.instance.execute(
        args: {'namespace': 'os', 'subcommand': 'command.exec', 'flags': {}},
        agentId: 'agent-other',
        enabledCliCommands: const {'store.read'},
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      expect(result['error'], contains('not allowed for this agent'));
    });
  });
}
