import 'dart:convert';

import 'package:flutter/material.dart';

import '../../controllers/flow/flow_editor_controller.dart';
import '../../controllers/flow/flow_executor.dart';
import '../../l10n/app_localizations.dart';

/// 定义头表单（方案 M5）：inputs / roles / limits / outputs / description。
///
/// 改动一律走主机的 `header` 操作（M1.5），App 只读不写 YAML。所以这台主机如果
/// 不支持 `header`，入口根本不会出来（[FlowHostCaps.canEditHeader]）。
void Function()? openFlowHeaderForm(
  BuildContext context,
  FlowEditorController controller,
) {
  return () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheet) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.8,
            child: FlowHeaderForm(controller: controller),
          ),
        ),
      );
}

class FlowHeaderForm extends StatefulWidget {
  const FlowHeaderForm({super.key, required this.controller});

  final FlowEditorController controller;

  @override
  State<FlowHeaderForm> createState() => _FlowHeaderFormState();
}

class _FlowHeaderFormState extends State<FlowHeaderForm> {
  late final TextEditingController _description;
  late final TextEditingController _maxTasks;
  late final TextEditingController _timeout;
  late final List<_InputRow> _inputs;
  late final List<_PairRow> _roles;
  late final List<_PairRow> _outputs;

  /// 打开时的原始头部映射。用来只发真正改过的字段，并保住表单没显示的键
  /// （roles.desc、inputs.default、limits 里的额外键、outputs 的非字符串值）。
  late final String _rawDescription;
  late final Map<String, dynamic> _rawLimits;
  late final Map<String, dynamic> _rawInputs;
  late final Map<String, dynamic> _rawRoles;
  late final Map<String, dynamic> _rawOutputs;

  @override
  void initState() {
    super.initState();
    final yaml = widget.controller.yaml;
    _rawDescription = FlowHeaderPeek.description(yaml);
    _rawLimits = FlowHeaderPeek.raw(yaml, 'limits');
    _rawInputs = FlowHeaderPeek.raw(yaml, 'inputs');
    _rawRoles = FlowHeaderPeek.raw(yaml, 'roles');
    _rawOutputs = FlowHeaderPeek.raw(yaml, 'outputs');
    _description = TextEditingController(text: _rawDescription);
    final maxTasks = (_rawLimits['max_tasks'] as num?)?.toInt() ?? 0;
    _maxTasks = TextEditingController(
      text: maxTasks == 0 ? '' : maxTasks.toString(),
    );
    _timeout = TextEditingController(
      text: _rawLimits['timeout']?.toString() ?? '',
    );
    _inputs = [
      for (final entry in _rawInputs.entries)
        _InputRow.from(entry.key.toString(), entry.value),
    ];
    _roles = [
      for (final entry in _rawRoles.entries)
        _PairRow.from(entry.key.toString(), entry.value),
    ];
    _outputs = [
      for (final entry in _rawOutputs.entries)
        _PairRow.from(entry.key.toString(), entry.value),
    ];
  }

  @override
  void dispose() {
    _description.dispose();
    _maxTasks.dispose();
    _timeout.dispose();
    for (final row in _inputs) {
      row.dispose();
    }
    for (final row in [..._roles, ..._outputs]) {
      row.dispose();
    }
    super.dispose();
  }

  /// 五个字段合成**一个**原子批次。以前五次 `setHeader(immediate:true)` 会拆成
  /// 两个往返，切页面还会丢掉后四个。
  Future<void> _apply() async {
    final c = widget.controller;
    final next = <String, Object?>{};

    final description = _description.text.trim();
    if (description != _rawDescription) {
      next['description'] = description;
    }

    final encodedLimits = <String, dynamic>{..._rawLimits};
    final maxTasks = int.tryParse(_maxTasks.text.trim()) ?? 0;
    if (maxTasks > 0) {
      encodedLimits['max_tasks'] = maxTasks;
    } else {
      encodedLimits.remove('max_tasks');
    }
    final timeout = _timeout.text.trim();
    if (timeout.isNotEmpty) {
      encodedLimits['timeout'] = timeout;
    } else {
      encodedLimits.remove('timeout');
    }
    if (!_sameJson(_rawLimits, encodedLimits)) next['limits'] = encodedLimits;

    final encodedInputs = <String, dynamic>{
      for (final row in _inputs)
        if (row.name.text.trim().isNotEmpty)
          row.name.text.trim(): row.encode(),
    };
    if (!_sameJson(_rawInputs, encodedInputs)) next['inputs'] = encodedInputs;

    final encodedRoles = <String, dynamic>{
      for (final row in _roles)
        if (row.key.text.trim().isNotEmpty)
          row.key.text.trim(): row.encodeForRole(),
    };
    if (!_sameJson(_rawRoles, encodedRoles)) next['roles'] = encodedRoles;

    final encodedOutputs = <String, dynamic>{
      for (final row in _outputs)
        if (row.key.text.trim().isNotEmpty)
          row.key.text.trim(): row.encodeForOutput(),
    };
    if (!_sameJson(_rawOutputs, encodedOutputs)) {
      next['outputs'] = encodedOutputs;
    }

    if (next.isEmpty) {
      Navigator.pop(context);
      return;
    }
    final ok = await c.setHeaders(next);
    if (!ok) {
      // 批次被拒：留在表单上让用户改，别悄悄关掉。
      return;
    }
    if (!mounted) return;
    Navigator.pop(context);
  }

  bool _sameJson(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(l10n.flow_headerTitle,
              style: theme.textTheme.titleMedium),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _section(l10n.flow_headerBasics, [
                TextField(
                  controller: _description,
                  decoration: InputDecoration(
                      labelText: l10n.flow_headerDescription, isDense: true),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _maxTasks,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                            labelText: l10n.flow_headerMaxTasks,
                            isDense: true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _timeout,
                        decoration: InputDecoration(
                            labelText: l10n.flow_headerTimeout,
                            hintText: '2h',
                            isDense: true),
                      ),
                    ),
                  ],
                ),
              ]),
              _section(l10n.flow_headerInputs, [
                for (final row in _inputs) _inputRow(row, l10n),
                _addRow(l10n.flow_headerAddInput, () => setState(() {
                      _inputs.add(_InputRow(name: '', type: 'string'));
                    })),
              ]),
              _section(l10n.flow_headerRoles, [
                for (final row in _roles)
                  _pairRow(row, l10n.flow_headerRoleName,
                      l10n.flow_headerRoleDesc),
                _addRow(l10n.flow_headerAddRole, () =>
                    setState(() => _roles.add(_PairRow('', '')))),
              ]),
              _section(l10n.flow_headerOutputs, [
                for (final row in _outputs)
                  _pairRow(row, l10n.flow_headerOutputName,
                      l10n.flow_headerOutputTemplate),
                _addRow(l10n.flow_headerAddOutput, () =>
                    setState(() => _outputs.add(_PairRow('', '')))),
              ]),
              // 说明限制：定义版本不给改，主机也不接受。
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  l10n.flow_headerHint,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            key: const ValueKey('header-apply'),
            onPressed: _apply,
            child: Text(l10n.flow_inspectorApply),
          ),
        ),
      ],
    );
  }

  Widget _section(String title, List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(height: 6),
          ...children,
        ],
      );

  Widget _addRow(String label, VoidCallback onTap) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.add, size: 16),
          label: Text(label),
        ),
      );

  Widget _pairRow(_PairRow row, String keyLabel, String valueLabel) => Row(
        children: [
          Expanded(
            child: TextField(
              controller: row.key,
              decoration:
                  InputDecoration(labelText: keyLabel, isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: row.value,
              decoration:
                  InputDecoration(labelText: valueLabel, isDense: true),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => setState(() {
              _roles.remove(row);
              _outputs.remove(row);
              row.dispose();
            }),
          ),
        ],
      );

  Widget _inputRow(_InputRow row, AppLocalizations l10n) => Card(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: row.name,
                      decoration: InputDecoration(
                          labelText: l10n.flow_headerInputName,
                          isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 110,
                    child: DropdownButtonFormField<String>(
                      initialValue: row.type,
                      isDense: true,
                      decoration: InputDecoration(
                          labelText: l10n.flow_headerInputType,
                          isDense: true),
                      items: [
                        for (final type in ['string', 'int', 'bool', 'list'])
                          DropdownMenuItem<String>(
                              value: type, child: Text(type)),
                      ],
                      onChanged: (v) =>
                          setState(() => row.type = v ?? 'string'),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() {
                      _inputs.remove(row);
                      row.dispose();
                    }),
                  ),
                ],
              ),
              Row(
                children: [
                  Switch(
                    value: row.required,
                    onChanged: (v) => setState(() => row.required = v),
                  ),
                  Text(l10n.flow_headerInputRequired),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: row.defaultValue,
                      decoration: InputDecoration(
                          labelText: l10n.flow_headerInputDefault,
                          isDense: true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

/// roles / outputs 的一行。`original` 留住原始值，没编辑过的行原样写回，
/// 免得把 `desc`、额外键、非字符串值抹掉。
class _PairRow {
  _PairRow(String key, String value, {this.original})
      : key = TextEditingController(text: key),
        value = TextEditingController(text: value);

  _PairRow.from(String key, Object? raw)
      : original = raw,
        key = TextEditingController(text: key),
        value = TextEditingController(text: _display(raw));

  _PairRow.forRole(String key, Object? raw)
      : original = raw,
        key = TextEditingController(text: key),
        value = TextEditingController(
          text: raw is Map ? (raw['desc']?.toString() ?? '') : '',
        );

  final TextEditingController key;
  final TextEditingController value;
  final Object? original;

  static String _display(Object? raw) =>
      raw is Map ? (raw['desc']?.toString() ?? '') : (raw?.toString() ?? '');

  /// roles：从原始 map 出发覆盖 desc，保住其他键。
  Object? encodeForRole() {
    final out = original is Map
        ? <String, dynamic>{...original as Map}
        : <String, dynamic>{};
    if (value.text.trim().isEmpty) {
      out.remove('desc');
    } else {
      out['desc'] = value.text.trim();
    }
    return out;
  }

  /// outputs：没改过就原样返回，避免把非字符串值压成 String。
  Object? encodeForOutput() {
    final before = original is Map
        ? (original as Map)['desc']?.toString() ?? ''
        : original?.toString() ?? '';
    if (value.text.trim() == before) return original ?? value.text.trim();
    return value.text.trim();
  }

  void dispose() {
    key.dispose();
    value.dispose();
  }
}

class _InputRow {
  _InputRow({
    required String name,
    required this.type,
    this.required = false,
    String defaultText = '',
    this.original,
  })  : name = TextEditingController(text: name),
       defaultValue = TextEditingController(text: defaultText);

  _InputRow.from(String key, Object? raw)
      : original = raw is Map ? Map<String, dynamic>.from(raw) : null,
        type = raw is Map ? (raw['type']?.toString() ?? 'string') : 'string',
        required = raw is Map && raw['required'] == true,
        name = TextEditingController(text: key),
        defaultValue = TextEditingController(
          text: raw is Map ? raw['default']?.toString() ?? '' : '',
        );

  final TextEditingController name;
  final TextEditingController defaultValue;
  final Map<String, dynamic>? original;
  String type;
  bool required;

  /// 从原始规格出发覆盖表单里的三个字段，保住没显示的键。
  Map<String, dynamic> encode() {
    final out = <String, dynamic>{...?original};
    out['type'] = type;
    if (required) {
      out['required'] = true;
    } else {
      out.remove('required');
    }
    if (defaultValue.text.trim().isEmpty) {
      out.remove('default');
    } else if (original?['default'] is num) {
      // 原来是数字，用户没改就别把它变成字符串。
      final n = num.tryParse(defaultValue.text.trim());
      out['default'] = n ?? defaultValue.text.trim();
    } else {
      out['default'] = defaultValue.text.trim();
    }
    return out;
  }

  void dispose() {
    name.dispose();
    defaultValue.dispose();
  }
}
