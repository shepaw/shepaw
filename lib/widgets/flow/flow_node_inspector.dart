import 'package:flutter/material.dart';

import '../../controllers/flow/flow_executor.dart';
import '../../controllers/flow/flow_field_catalog.dart';
import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_models.dart';
import 'flow_executor_field.dart';
import 'flow_node_tree.dart';

/// 节点检查器（方案 C.4）：底部抽屉表单。字段表由 Hub 下发（`flow_schema_resp`），
/// 当前值取自节点的 `fields`。只产出 `set` 操作，真正改 YAML 的是 Hub。
class FlowNodeInspector extends StatefulWidget {
  const FlowNodeInspector({
    super.key,
    required this.node,
    required this.schema,
    required this.onApply,
    required this.onDelete,
    required this.onWrap,
    required this.onUnwrap,
    required this.onAddAfter,
    this.roles = const [],
    this.onPickAgent,
  });

  final FlowNode node;
  final FlowSchema schema;

  /// 定义头里的角色名，喂给「谁来做」选择器。
  final List<String> roles;

  /// 打开 Agent 选择器；为 null 时 Agent 退化成手输。
  final Future<String?> Function()? onPickAgent;

  /// 改动的字段（点分路径 → 新值；空值表示清掉）。
  final void Function(Map<String, Object?> changes) onApply;
  final VoidCallback onDelete;

  /// `par` / `loop`。
  final void Function(String kind) onWrap;
  final VoidCallback onUnwrap;
  final VoidCallback onAddAfter;

  @override
  State<FlowNodeInspector> createState() => _FlowNodeInspectorState();
}

class _FlowNodeInspectorState extends State<FlowNodeInspector> {
  final Map<String, TextEditingController> _text = {};
  final Map<String, String?> _enums = {};

  /// 为 null 表示用户没动过执行者：那就一个字段都别发，免得把现有的清掉。
  FlowExecutor? _executor;

  bool get _isTask => widget.node.kind == 'task';

  /// `task.role` / `task.agent` 交给「谁来做」选择器，不再单独出文本框。
  List<FlowSchemaField> get _fields => [
        for (final field
            in FlowFieldCatalog.fieldsFor(widget.node.kind, widget.schema))
          if (!_isTask ||
              (field.name != 'task.role' && field.name != 'task.agent'))
            field,
      ];

  @override
  void initState() {
    super.initState();
    for (final field in _fields) {
      final current = flowFieldValue(widget.node.fields, field.name);
      if (field.type == 'enum') {
        _enums[field.name] = current?.toString();
      } else {
        _text[field.name] =
            TextEditingController(text: current?.toString() ?? '');
      }
    }
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 和打开时不一样的字段。整数字段写成数字，空值表示清掉。
  Map<String, Object?> _changes() {
    final changes = <String, Object?>{};
    final executor = _executor;
    if (_isTask && executor != null) {
      changes.addAll(executor.ops());
    }
    for (final field in _fields) {
      final before = flowFieldValue(widget.node.fields, field.name)?.toString();
      final String? after = field.type == 'enum'
          ? _enums[field.name]
          : _text[field.name]!.text.trim();
      if ((before ?? '') == (after ?? '')) continue;
      if (after == null || after.isEmpty) {
        changes[field.name] = null;
      } else if (field.type == 'int') {
        changes[field.name] = int.tryParse(after) ?? after;
      } else {
        changes[field.name] = after;
      }
    }
    return changes;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final node = widget.node;
    final isContainer =
        {'seq', 'par', 'loop', 'map', 'if'}.contains(node.kind) &&
            node.children.isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 12,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(flowKindTitle(l10n, node),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (_isTask)
                FlowExecutorField(
                  node: widget.node,
                  roles: widget.roles,
                  onPickAgent: widget.onPickAgent,
                  onChanged: (executor) => setState(() => _executor = executor),
                ),
              for (final field in _fields)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  // Hub 下发的 label 是中文；其他语言退回字段名。
                  child: field.type == 'enum'
                      ? DropdownButtonFormField<String?>(
                          key: ValueKey('f:${field.name}'),
                          initialValue: _enums[field.name],
                          decoration: InputDecoration(
                            labelText: zh ? field.label : field.name,
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem<String?>(
                                value: null, child: Text('—')),
                            for (final option in field.options)
                              DropdownMenuItem<String?>(
                                  value: option, child: Text(option)),
                          ],
                          onChanged: (v) =>
                              setState(() => _enums[field.name] = v),
                        )
                      : TextField(
                          key: ValueKey('f:${field.name}'),
                          controller: _text[field.name],
                          keyboardType: field.type == 'int'
                              ? TextInputType.number
                              : TextInputType.multiline,
                          minLines: 1,
                          maxLines: field.type == 'text' ? 6 : 1,
                          decoration: InputDecoration(
                            labelText: zh ? field.label : field.name,
                            isDense: true,
                          ),
                        ),
                ),
              const SizedBox(height: 8),
              FilledButton(
                key: const ValueKey('inspector-apply'),
                onPressed: () => widget.onApply(_changes()),
                child: Text(l10n.flow_inspectorApply),
              ),
              const Divider(height: 24),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton(
                    onPressed: widget.onAddAfter,
                    child: Text(l10n.flow_addAfter),
                  ),
                  OutlinedButton(
                    onPressed: () => widget.onWrap('par'),
                    child: Text(l10n.flow_wrapPar),
                  ),
                  OutlinedButton(
                    onPressed: () => widget.onWrap('loop'),
                    child: Text(l10n.flow_wrapLoop),
                  ),
                  if (isContainer)
                    OutlinedButton(
                      onPressed: widget.onUnwrap,
                      child: Text(l10n.flow_unwrap),
                    ),
                  TextButton(
                    onPressed: widget.onDelete,
                    style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error),
                    child: Text(l10n.flow_inspectorDelete),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
