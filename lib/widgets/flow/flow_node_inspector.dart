import 'dart:convert';

import 'package:flutter/material.dart';

import '../../controllers/flow/flow_edit_ops.dart';
import '../../controllers/flow/flow_executor.dart';
import '../../controllers/flow/flow_field_catalog.dart';
import '../../controllers/flow/flow_references.dart';
import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_field_schema.dart';
import '../../peer/models/flow_models.dart';
import 'flow_executor_field.dart';
import 'flow_field_editors.dart';
import 'flow_node_tree.dart';

/// 节点检查器：底部抽屉表单。
///
/// 字段表由 [FlowFieldCatalog] 把主机 schema 和客户端补充表合并而来（标量 +
/// 列表 / 映射 / 条件 / 结构化输出）。当前值取自节点的 `fields`，改动只产出
/// `set` 操作，真正改 YAML 的是 Hub。
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
    this.tree = const [],
    this.yaml = '',
  });

  final FlowNode node;
  final FlowSchema schema;

  /// 改动的字段（点分路径 → 新值；null 表示清掉）。
  final void Function(Map<String, Object?> changes) onApply;
  final VoidCallback onDelete;

  /// `par` / `loop`。
  final void Function(String kind) onWrap;
  final VoidCallback onUnwrap;
  final VoidCallback onAddAfter;

  final List<String> roles;
  final Future<String?> Function()? onPickAgent;

  /// 当前节点树和草稿（生成「插入引用」候选和 int 输入列表）。
  final List<FlowNode> tree;
  final String yaml;

  @override
  State<FlowNodeInspector> createState() => _FlowNodeInspectorState();
}

class _FlowNodeInspectorState extends State<FlowNodeInspector> {
  late final List<FlowFieldSpec> _specs;
  late final Map<String, Object?> _original;
  final Map<String, Object?> _values = {};

  /// 执行者的选中状态由检查器持有（[FlowExecutorField] 是无状态的展示）。
  /// 为 null 表示用户没动过：那就一个字段都别发，免得把现有的清掉。
  late FlowExecutor _executor;
  bool _executorDirty = false;

  bool get _isTask => widget.node.kind == 'task';

  @override
  void initState() {
    super.initState();
    _executor = FlowExecutor.of(widget.node.fields);
    _executorDirty = false;
    // `task.role` / `task.agent` / `task.uses` 都交给「谁来做」选择器，不再单独
    // 出文本框（否则会和选择器在同一批里发出两个互相冲突的执行者）。
    _specs = [
      for (final spec
          in FlowFieldCatalog.specsFor(widget.node.kind, widget.schema))
        if (!_isTask ||
            (spec.path != 'task.role' &&
                spec.path != 'task.agent' &&
                spec.path != 'task.uses'))
          spec,
    ];
    for (final spec in _specs) {
      _values[spec.path] = flowFieldValue(widget.node.fields, spec.path);
    }
    _original = Map<String, Object?>.from(_values);
  }

  /// 和打开时不一样的字段。映射 / 列表按 JSON 比，不然内容相同也会被判成改动。
  Map<String, Object?> _changes() {
    final changes = <String, Object?>{};
    if (_isTask && _executorDirty) {
      changes.addAll(_executor.ops());
    }
    for (final entry in _values.entries) {
      final before = _original[entry.key];
      if (_same(before, entry.value)) continue;
      // 必填字段被清空：不发 null（主机解析会失败），界面上标红让用户填回去。
      final spec = _specs.where((s) => s.path == entry.key).firstOrNull;
      // 必填字段被清空、或编辑器标红的非法值：不发（主机解析会失败），界面上
      // 标红让用户填回去。
      if (spec == null || !isFlowFieldValueValid(spec, entry.value)) continue;
      changes[entry.key] = entry.value;
    }
    return changes;
  }

  bool _same(Object? a, Object? b) {
    if (a == null || b == null) return a == b;
    if (a is Map || a is List || b is Map || b is List) {
      return jsonEncode(a) == jsonEncode(b);
    }
    return a.toString() == b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final node = widget.node;
    final isContainer = FlowStepDefaults.isContainer(node.kind);
    final refCandidates = FlowReferences.of(
      tree: widget.tree,
      currentNodeId: node.id,
      yaml: widget.yaml,
    );
    final intInputs = [
      for (final spec in peekInputs(widget.yaml))
        if (spec.type == 'int') spec.name,
    ];

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
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              if (_isTask)
                FlowExecutorField(
                  node: node,
                  current: _executor,
                  roles: widget.roles,
                  onPickAgent: widget.onPickAgent,
                  onChanged: (executor) => setState(() {
                    _executor = executor;
                    _executorDirty = true;
                  }),
                ),
              for (final spec in _specs)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: FlowFieldEditor(
                    key: ValueKey('field-${spec.path}'),
                    spec: spec,
                    current: _original[spec.path],
                    refCandidates: FlowReferences.supports(spec.path)
                        ? refCandidates
                        : const [],
                    intInputNames: spec.shape == FlowFieldShape.intOrInput
                        ? intInputs
                        : const [],
                    onChanged: (value) => _values[spec.path] = value,
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
                  OutlinedButton(
                    onPressed: widget.onDelete,
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
