import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/clis/cli_command_allowlist.dart';
import 'package:shepaw/services/cli_execution_gate.dart';

import '../storage/test_harness.dart';

/// P0-4 回归：allowlist 的「空集」曾经同时表示「不受限」和「什么都不许」，
/// 且 `??` 是覆盖而非交集。这里把三态语义与交集原语钉死。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    SharedPreferences.setMockInitialValues({});
  });

  group('cliIntersectAllowlists', () {
    test('namespace 与更具体的命令取较紧的那条', () {
      expect(cliIntersectAllowlists({'store'}, {'store.read'}), {'store.read'});
      expect(cliIntersectAllowlists({'store.read'}, {'store'}), {'store.read'});
    });

    test('点号子命名空间同理', () {
      expect(
        cliIntersectAllowlists({'context'}, {'context.profile.query'}),
        {'context.profile.query'},
      );
      expect(
        cliIntersectAllowlists({'context.profile'}, {'context'}),
        {'context.profile'},
      );
    });

    test('不可比的条目被丢弃', () {
      expect(
        cliIntersectAllowlists({'store', 'help'}, {'os'}),
        isEmpty,
      );
      // 只有 store 重合，os / help 各自落单。
      expect(
        cliIntersectAllowlists({'store', 'os'}, {'store', 'help'}),
        {'store'},
      );
    });

    test('相等条目原样保留', () {
      expect(cliIntersectAllowlists({'peer.status'}, {'peer.status'}),
          {'peer.status'});
    });

    test('null 侧表示该轴不限制，返回另一侧原值', () {
      expect(cliIntersectAllowlists(null, {'store'}), {'store'});
      expect(cliIntersectAllowlists({'store'}, null), {'store'});
      expect(cliIntersectAllowlists(null, null), isNull);
      // 空集不是「不限制」——它是明确的「什么都不许」。
      expect(cliIntersectAllowlists(null, const <String>{}), isEmpty);
      expect(cliIntersectAllowlists(const <String>{}, {'store'}), isEmpty);
    });

    test('空集与任何一侧相交都是空集', () {
      expect(cliIntersectAllowlists(const <String>{}, const <String>{}), isEmpty);
      expect(cliIntersectAllowlists(const <String>{}, null), isEmpty);
    });

    test('随机对拍：交集恰好等于两侧同时放行的命令集', () {
      // 引理：条目 x 放行 c ⟺ x 是 c 的点号前缀。交集取较长的可比条目，
      // 因此对任意 c，allowed(A∩B, c) == allowed(A, c) && allowed(B, c)。
      // 不靠证明的自觉 —— 用随机集合对拍。
      const corpus = [
        'store',
        'store.read',
        'store.write',
        'store.list',
        'os',
        'os.command.exec',
        'os.file.read',
        'help',
        'context',
        'context.profile.query',
        'context.agents.get',
        'peer',
        'peer.status',
        'workflow',
        'workflow.create',
      ];
      final rng = Random(20260911);

      Set<String> randomSet() => {
            for (final entry in corpus)
              if (rng.nextBool()) entry,
          };

      for (var i = 0; i < 300; i++) {
        final a = randomSet();
        final b = randomSet();
        final intersection = cliIntersectAllowlists(a, b)!;
        for (final c in corpus) {
          expect(
            cliCommandAllowed(intersection, c),
            cliCommandAllowed(a, c) && cliCommandAllowed(b, c),
            reason: 'A=$a B=$b command=$c intersection=$intersection',
          );
        }
      }
    });
  });

  group('空集语义统一', () {
    test('cliNamespaceVisible 对空集返回 false', () {
      expect(cliNamespaceVisible(const <String>{}, 'store'), isFalse);
      expect(cliNamespaceVisible(const <String>{}, 'help'), isFalse);
    });

    test('cliCommandAllowed 对空集返回 false（与上一条一致）', () {
      expect(cliCommandAllowed(const <String>{}, 'store'), isFalse);
      expect(cliCommandAllowed(const <String>{}, 'help'), isFalse);
    });

    test('cliFilterNamespaces 把 null 当不受限、把 {} 当全禁', () {
      const all = ['store', 'help', 'os'];
      expect(cliFilterNamespaces(all), all);
      // 空集 = 一条都不许 → 回退到 help（模型仍需一个可调用的命名空间）。
      expect(cliFilterNamespaces(all, enabledCliCommands: const {}), ['help']);
    });

    test('cliSchemaRestrictionNote 对空集仍标注受限', () {
      expect(cliSchemaRestrictionNote(enabledCliCommands: const {}),
          contains('per-agent: (none)'));
      expect(cliSchemaRestrictionNote(), isNull);
    });

    test('cliFilterSubcommands 对空集不再视为「整命名空间放行」', () {
      // 旧实现里 isEmpty 会被当成 fullyGranted → 返回 null（枚举全开）。
      expect(
        cliFilterSubcommands(
          namespaces: const ['store'],
          enabledCliCommands: const {'store.write'},
        ),
        ['write'],
      );
    });
  });

  group('CliExecutionGate 的三态', () {
    test('null = 不受限：放行任意命令', () async {
      final raw = await CliExecutionGate.instance.execute(
        args: {'namespace': 'store', 'subcommand': 'read', 'flags': {}},
        agentId: 'agent-other',
      );
      final result = _decode(raw);
      expect(result['error']?.toString() ?? '', isNot(contains('not allowed')));
    });

    test('{} = 全禁：连 store.read 也拒绝', () async {
      final raw = await CliExecutionGate.instance.execute(
        args: {'namespace': 'store', 'subcommand': 'read', 'flags': {}},
        agentId: 'agent-other',
        enabledCliCommands: const {},
      );
      final result = _decode(raw);
      expect(result['error'], contains('not allowed for this agent'));
      expect(result['error'], contains('(none)'));
    });

    test('非空 = 只放行列出的命令', () async {
      final allowed = _decode(await CliExecutionGate.instance.execute(
        args: {'namespace': 'store', 'subcommand': 'read', 'flags': {}},
        agentId: 'agent-other',
        enabledCliCommands: const {'store'},
      ));
      expect(allowed['error']?.toString() ?? '', isNot(contains('not allowed')));

      final denied = _decode(await CliExecutionGate.instance.execute(
        args: {'namespace': 'store', 'subcommand': 'read', 'flags': {}},
        agentId: 'agent-other',
        enabledCliCommands: const {'os'},
      ));
      expect(denied['error'], contains('not allowed for this agent'));
    });
  });
}

Map<String, dynamic> _decode(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;
