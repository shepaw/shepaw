import 'package:flutter/material.dart';

import '../../controllers/flow/flow_edit_ops.dart';
import '../../controllers/flow/flow_outline.dart';
import '../../l10n/app_localizations.dart';

/// 行菜单里的动作。
enum FlowOutlineMenuAction {
  /// 往这个节点里加子步骤。
  insertChild,

  /// 换节点类型。
  retype,

  /// 移进上一个兄弟（它得是容器）。
  moveIntoPrevious,

  /// 和上一个兄弟一起包进一个新容器。
  wrapWithPrevious,

  /// 显式跨分支移动（`if` 内不靠下标跨 then/else）。
  moveToBranch,
}

/// 菜单的选择。[kind] 对 [FlowOutlineMenuAction.retype] 是目标类型，
/// 对 [wrapWithPrevious] 是容器类型；[branch] 是 `if` 的哪一支。
typedef FlowOutlineMenuChoice = ({
  FlowOutlineMenuAction action,
  String? kind,
  String? branch,
});

/// 大纲行上的「⋯」菜单。
///
/// 缩进**不再隐式包裹**：以前「⇥」遇到叶子兄弟会悄悄造一个 `seq`，用户并不知
/// 道自己多了一层，包成 `par` / `loop` 还会改变执行语义（并发、重复）。现在拆
/// 成两个显式条目，各自写清会发生什么。
Future<FlowOutlineMenuChoice?> showFlowOutlineMenu(
  BuildContext context, {
  required FlowOutlineRow row,
  required bool canRetype,
}) {
  return showModalBottomSheet<FlowOutlineMenuChoice>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) =>
        _Menu(row: row, canRetype: canRetype),
  );
}

class _Menu extends StatelessWidget {
  const _Menu({required this.row, required this.canRetype});

  final FlowOutlineRow row;
  final bool canRetype;

  static const _containerKinds = ['seq', 'par', 'loop'];
  static const _allKinds = [
    'task',
    'seq',
    'par',
    'loop',
    'if',
    'map',
    'set',
    'call',
    'gate',
    'plan',
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final node = row.node;
    final previous = row.previousSibling;
    // `if` 也是容器，只是子节点分在 then / else 两支里。
    final isContainer =
        node.kind == 'if' || FlowStepDefaults.isContainer(node.kind);
    final previousIsContainer =
        previous != null && FlowStepDefaults.isContainer(previous.kind);

    Widget section(String title, List<Widget> children) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                title,
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            ...children,
          ],
        );

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(node.id, style: theme.textTheme.titleMedium),
            ),
            if (isContainer)
              section(
                l10n.flow_outlineAddChild,
                [
                  if (node.kind == 'if') ...[
                    _item(context, l10n.flow_outlineThen, () {
                      Navigator.pop(
                          context,
                          (
                            action: FlowOutlineMenuAction.insertChild,
                            kind: null,
                            branch: 'then',
                          ));
                    }),
                    _item(context, l10n.flow_outlineElse, () {
                      Navigator.pop(
                          context,
                          (
                            action: FlowOutlineMenuAction.insertChild,
                            kind: null,
                            branch: 'else',
                          ));
                    }),
                  ] else
                    _item(context, l10n.flow_outlineAddChild, () {
                      Navigator.pop(
                          context,
                          (
                            action: FlowOutlineMenuAction.insertChild,
                            kind: null,
                            branch: null,
                          ));
                    }),
                ],
              ),
            if (previous != null && previousIsContainer)
              section(l10n.flow_outlineIndent, [
                _item(
                  context,
                  l10n.flow_outlineMoveInto(previous.id),
                  () {
                    Navigator.pop(
                        context,
                        (
                          action: FlowOutlineMenuAction.moveIntoPrevious,
                          kind: null,
                          branch: null,
                        ));
                  },
                ),
              ]),
            if (previous != null)
              section(l10n.flow_outlineWrapWith, [
                for (final kind in _containerKinds)
                  _item(context, kind, () {
                    Navigator.pop(
                        context,
                        (
                          action: FlowOutlineMenuAction.wrapWithPrevious,
                          kind: kind,
                          branch: null,
                        ));
                  }),
              ]),
            // 在 if 里时给显式的跨分支入口：上移/下移刻意不跨分支（会跳错支）。
            if (row.branch != null)
              section(l10n.flow_outlineMoveToBranch, [
                for (final branch in ['then', 'else'])
                  if (branch != row.branch)
                    _item(
                      context,
                      branch == 'then' ? l10n.flow_outlineThen : l10n.flow_outlineElse,
                      () {
                        Navigator.pop(
                            context,
                            (
                              action: FlowOutlineMenuAction.moveToBranch,
                              kind: null,
                              branch: branch,
                            ));
                      },
                    ),
              ]),
            if (canRetype)
              section(l10n.flow_outlineRetype, [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final kind in _allKinds)
                      if (kind != node.kind)
                        ActionChip(
                          key: ValueKey('retype-$kind'),
                          label: Text(kind),
                          onPressed: () {
                            Navigator.pop(
                                context,
                                (
                                  action: FlowOutlineMenuAction.retype,
                                  kind: kind,
                                  branch: null,
                                ));
                          },
                        ),
                  ],
                ),
                const SizedBox(height: 8),
              ]),
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext context, String label, VoidCallback onTap) =>
      ListTile(
        title: Text(label),
        onTap: onTap,
      );
}
