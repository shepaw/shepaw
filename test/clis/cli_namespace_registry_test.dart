import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/cli_base.dart';
import 'package:shepaw/clis/shepaw/shepaw_cli.dart';
import 'package:shepaw/services/cli_namespace_registry.dart';
import 'package:shepaw/services/cli_tool_registry.dart';

/// P0-1 回归：命名空间「事实」曾经有 4 份副本且已漂移。
///
/// `CliNamespaceRegistry` 硬编码 11 项（缺 `os` / `workflow` / `store`），
/// 而 `CliCommandSelectScreen` 用它的 `allCommandIds` 判断「是否全选」——
/// 这三个命名空间因此会被静默写掉（见 P0-2 bug 1）。这些断言把「派生自
/// ShepawCLI」钉死，副本再次出现时立刻失败。
void main() {
  group('CliNamespaceRegistry 派生自 ShepawCLI', () {
    test('顶层命名空间键集合与 ShepawCLI 完全一致', () {
      expect(
        CliNamespaceRegistry.instance.namespaces.keys.toSet(),
        ShepawCLI.instance.namespaces.keys.toSet(),
      );
    });

    test('allCommandIds 覆盖每个有命令的命名空间（含 os / store / workflow）', () {
      // 递归判断命名空间是否真的注册了命令。`help` 是裸命名空间：它不注册
      // 自己的命令，只在 execute 里返回用法说明，所以不在期望集合内。
      bool hasCommands(CliNamespace ns) =>
          ns.commands.isNotEmpty || ns.subNamespaces.values.any(hasCommands);

      final expected = ShepawCLI.instance.namespaces.entries
          .where((e) => hasCommands(e.value))
          .map((e) => e.key)
          .toSet();
      final covered = CliNamespaceRegistry.instance.allCommandIds
          .map((id) => id.split('.').first)
          .toSet();

      expect(
        covered,
        containsAll(expected),
        reason: '有命名空间在 allCommandIds 里一条命令都没有 —— '
            '命令选择器会把它当成「未注册」并静默丢弃',
      );
      // 显式点名，防止将来有人把派生改回硬编码时只保留旧的 11 项。
      expect(covered, containsAll(['os', 'store', 'workflow']));
    });

    test('label 由 id 首字母大写推导，description 取自命名空间', () {
      for (final entry in ShepawCLI.instance.namespaces.entries) {
        final info = CliNamespaceRegistry.instance.namespaces[entry.key]!;
        expect(info.id, entry.key);
        expect(info.description, entry.value.description);
        expect(info.label, CliNamespaceRegistry.labelFor(entry.key));
        expect(info.label, isNotEmpty);
      }
    });

    test('嵌套命名空间展开为点号命令 id', () {
      final ids = CliNamespaceRegistry.instance.allCommandIds;
      // context.agents.get 是两层子命名空间下的命令。
      expect(ids, contains('context.agents.get'));
      // os 的子命名空间同理。
      expect(ids, contains('os.command.exec'));
    });

    test('groupCommandsByNamespace 还原顶层命名空间', () {
      final grouped = CliNamespaceRegistry.instance.groupCommandsByNamespace(
        const ['context.agents.get', 'os.command.exec', 'help'],
      );
      expect(grouped.keys.toSet(), {'context', 'os', 'help'});
    });
  });

  group('CliToolRegistry 保留名派生自内置命名空间', () {
    test('store / workflow 不再可被外部工具遮蔽', () {
      // _reservedNamespaces 是私有的，用安装路径的公开断言代替：内置名集合
      // 必须包含这两个（旧硬编码列表漏了它们）。
      expect(
        ShepawCLI.instance.builtinNamespaceNames,
        containsAll(['store', 'workflow']),
      );
    });

    test('保留名不含外部命名空间自身', () {
      // 外部工具在重扫描期间仍留在 ShepawCLI.namespaces 里；若把它们算作
      // 保留名，所有已安装工具都会被判为与内置冲突并消失。
      final builtin = ShepawCLI.instance.builtinNamespaceNames;
      for (final tool in CliToolRegistry.instance.tools) {
        expect(builtin, isNot(contains(tool.namespace)));
      }
    });
  });
}
