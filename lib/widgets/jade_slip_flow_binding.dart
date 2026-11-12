import 'dart:convert';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/jade_slip.dart';

/// 玉简绑定工作流的编辑表单：预设输入 + 角色绑定。
///
/// 模板自身的 `inputs` / `roles` 名字由调用方给（派发页拿得到定义）；拿不到时
/// 用绑定里已有的键兜底，保证至少能改已经预填过的值。表单自己保存一份
/// `_draft`：连续输入时每次都是基于「上一版的完整绑定」改，不依赖父页面
/// 异步保存回来得够快，也不会被保存途中的旧快照抢回去。
class JadeSlipFlowBindingForm extends StatefulWidget {
  const JadeSlipFlowBindingForm({
    super.key,
    required this.binding,
    required this.onChanged,
    this.inputNames = const [],
    this.roles = const [],
  });

  final JadeSlipFlowBinding binding;
  final List<String> inputNames;
  final List<String> roles;
  final ValueChanged<JadeSlipFlowBinding> onChanged;

  @override
  State<JadeSlipFlowBindingForm> createState() =>
      _JadeSlipFlowBindingFormState();
}

class _JadeSlipFlowBindingFormState extends State<JadeSlipFlowBindingForm> {
  late JadeSlipFlowBinding _draft;

  /// 已经见过（初值或自己发出去）的绑定签名。父页面保存期间会用旧 binding
  /// 重建一次，这里要认出它是「回显」而不是外部换模板，否则正在输入的值会被
  /// 抢回去。真正的新绑定（换模板 / 主机回写）签名不在集合里，正常采纳。
  final Set<String> _seen = <String>{};
  final Map<String, TextEditingController> _controllers = {};

  static const _inputPrefix = 'i:';
  static const _rolePrefix = 'r:';

  @override
  void initState() {
    super.initState();
    _adopt(widget.binding);
  }

  @override
  void didUpdateWidget(covariant JadeSlipFlowBindingForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_seen.contains(_signature(widget.binding))) {
      _adopt(widget.binding);
    }
    // 模板的 inputs / roles 名字变了时补齐控制器；didUpdateWidget 之后本来就会
    // 重建，不需要 setState。
    _syncControllers();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
    super.dispose();
  }

  void _adopt(JadeSlipFlowBinding binding) {
    _draft = binding;
    _seen
      ..clear()
      ..add(_signature(binding));
    _syncControllers();
  }

  static Map<String, String> _sorted(Map<String, String> source) => {
        for (final key in source.keys.toList()..sort()) key: source[key]!,
      };

  static String _signature(JadeSlipFlowBinding binding) => jsonEncode([
        binding.scope,
        binding.name,
        binding.revision,
        _sorted(binding.inputs),
        _sorted(binding.bindings),
        _sorted(binding.inputFrom),
      ]);

  /// 调用方给的名字在前，绑定里已有的键补在后面（模板删掉的旧值也要能清掉）。
  List<String> _names(List<String> declared, Iterable<String> stored) {
    final result = <String>[];
    for (final raw in [...declared, ...stored]) {
      final name = raw.trim();
      if (name.isNotEmpty && !result.contains(name)) result.add(name);
    }
    return result;
  }

  void _syncControllers() {
    final needed = <String, String>{
      for (final name in _names(widget.inputNames, _draft.inputs.keys))
        '$_inputPrefix$name': _draft.inputs[name] ?? '',
      for (final role in _names(widget.roles, _draft.bindings.keys))
        '$_rolePrefix$role': _draft.bindings[role] ?? '',
    };
    for (final key in _controllers.keys.toList()) {
      if (needed.containsKey(key)) continue;
      _controllers.remove(key)?.dispose();
    }
    needed.forEach((key, value) {
      final controller = _controllers.putIfAbsent(
        key,
        () => TextEditingController(text: value),
      );
      if (controller.text != value) controller.text = value;
    });
  }

  TextEditingController _controller(String key) => _controllers.putIfAbsent(
        key,
        () => TextEditingController(),
      );

  void _editInput(String name, String value) {
    final inputs = Map<String, String>.of(_draft.inputs);
    final inputFrom = Map<String, String>.of(_draft.inputFrom);
    if (value.isEmpty) {
      // 清空 = 交回自动映射；只留一个 manual 标记会让自动映射永远失效。
      inputs.remove(name);
      inputFrom.remove(name);
    } else {
      inputs[name] = value;
      // 手填的值不许开跑时的玉简字段自动映射覆盖掉。
      inputFrom[name] = 'manual';
    }
    _emit(_draft.copyWith(inputs: inputs, inputFrom: inputFrom));
  }

  void _editRole(String role, String value) {
    final bindings = Map<String, String>.of(_draft.bindings);
    if (value.isEmpty) {
      bindings.remove(role);
    } else {
      bindings[role] = value;
    }
    _emit(_draft.copyWith(bindings: bindings));
  }

  void _emit(JadeSlipFlowBinding next) {
    _draft = next;
    _seen.add(_signature(next));
    // revision / scope / name 一律由 copyWith 原样带着走。
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final binding = _draft;
    final labelStyle = theme.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w600,
      color: scheme.onSurfaceVariant,
    );
    final captionStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final inputNames = _names(widget.inputNames, binding.inputs.keys);
    final roles = _names(widget.roles, binding.bindings.keys);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(Icons.account_tree_outlined,
                size: 15, color: scheme.onSurfaceVariant),
            Text(
              binding.name.isEmpty ? l10n.jadeSlip_flowNone : binding.name,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (binding.scope.isNotEmpty)
              Text(binding.scope, style: captionStyle),
            Text(
              binding.revision == null
                  ? l10n.jadeSlip_flowRevisionLatest
                  : l10n.jadeSlip_flowVersion(binding.revision!),
              style: captionStyle,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(l10n.jadeSlip_flowPresetInputs, style: labelStyle),
        const SizedBox(height: 6),
        for (final name in inputNames)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: TextField(
              key: ValueKey('slip-flow-input-$name'),
              controller: _controller('$_inputPrefix$name'),
              style: theme.textTheme.bodyMedium,
              decoration: _fieldDecoration(
                context,
                '${l10n.jadeSlip_flowInput} · $name',
              ),
              onChanged: (value) => _editInput(name, value),
            ),
          ),
        const SizedBox(height: 2),
        Text(l10n.jadeSlip_flowRoleBindings, style: labelStyle),
        const SizedBox(height: 6),
        for (final role in roles)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: TextField(
              key: ValueKey('slip-flow-role-$role'),
              controller: _controller('$_rolePrefix$role'),
              style: theme.textTheme.bodyMedium,
              decoration: _fieldDecoration(
                context,
                '${l10n.jadeSlip_flowRole} · $role',
              ),
              onChanged: (value) => _editRole(role, value),
            ),
          ),
      ],
    );
  }

  InputDecoration _fieldDecoration(BuildContext context, String label) {
    final scheme = Theme.of(context).colorScheme;
    return InputDecoration(
      isDense: true,
      labelText: label,
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.5)),
      ),
    );
  }
}
