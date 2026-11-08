import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../controllers/flow/flow_editor_controller.dart';
import '../../controllers/flow/flow_executor.dart';
import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_models.dart';

/// 流程设置：嵌在属性面板里，改动直接 `setHeaders`，没有「应用」按钮。
class FlowHeaderForm extends StatefulWidget {
  const FlowHeaderForm({
    super.key,
    required this.controller,
    this.readOnly = false,
    this.onPickAgent,
    this.tree = const [],
  });

  final FlowEditorController controller;
  final bool readOnly;
  final Future<String?> Function()? onPickAgent;
  final List<FlowNode> tree;

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
  late String _rawDescription;
  late Map<String, dynamic> _rawLimits;
  late Map<String, dynamic> _rawInputs;
  late Map<String, dynamic> _rawRoles;
  late Map<String, dynamic> _rawOutputs;

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

  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
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

  void _schedule() {
    if (widget.readOnly) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) unawaited(_apply());
    });
  }

  /// 五个字段合成**一个**原子批次。
  Future<void> _apply() async {
    if (widget.readOnly) return;
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

    if (next.isEmpty) return;
    final ok = await c.setHeaders(next);
    if (!ok || !mounted) return;
    _rawDescription = description;
    _rawLimits = encodedLimits;
    _rawInputs = encodedInputs;
    _rawRoles = encodedRoles;
    _rawOutputs = encodedOutputs;
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(l10n.flow_headerTitle,
              style: theme.textTheme.titleMedium),
        ),
        if (widget.readOnly)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(l10n.flow_readOnlyHostHint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _section(l10n.flow_headerBasics, [
                TextField(
                  controller: _description,
                  readOnly: widget.readOnly,
                  decoration: InputDecoration(
                      hintText: l10n.flow_descPlaceholder, isDense: true),
                  onChanged: (_) => _schedule(),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _maxTasks,
                        readOnly: widget.readOnly,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                            labelText: l10n.flow_headerMaxTasks,
                            isDense: true),
                        onChanged: (_) => _schedule(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _timeout,
                        readOnly: widget.readOnly,
                        decoration: InputDecoration(
                            labelText: l10n.flow_headerTimeout,
                            hintText: '2h',
                            isDense: true),
                        onChanged: (_) => _schedule(),
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
            ],
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
                      onChanged: widget.readOnly
                          ? null
                          : (v) {
                              setState(() => row.type = v ?? 'string');
                              _schedule();
                            },
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
                    onChanged: widget.readOnly
                        ? null
                        : (v) {
                            setState(() => row.required = v);
                            _schedule();
                          },
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
