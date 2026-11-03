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

  @override
  void initState() {
    super.initState();
    final yaml = widget.controller.yaml;
    _description =
        TextEditingController(text: FlowHeaderPeek.description(yaml));
    final limits = FlowHeaderPeek.limits(yaml);
    _maxTasks = TextEditingController(
      text: limits.maxTasks == 0 ? '' : limits.maxTasks.toString(),
    );
    _timeout = TextEditingController(text: limits.timeout);
    _inputs = [
      for (final spec in peekInputs(yaml))
        _InputRow(
          name: spec.name,
          type: spec.type,
          required: spec.required,
          defaultText: spec.defaultValue ?? '',
        ),
    ];
    _roles = [
      for (final role in peekRoles(yaml)) _PairRow(role, ''),
    ];
    _outputs = [
      for (final entry in FlowHeaderPeek.outputs(yaml).entries)
        _PairRow(entry.key, entry.value),
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

  void _apply() {
    final c = widget.controller;
    c.setHeader('description', _description.text.trim());
    c.setHeader('limits', {
      'max_tasks': int.tryParse(_maxTasks.text.trim()) ?? 0,
      if (_timeout.text.trim().isNotEmpty) 'timeout': _timeout.text.trim(),
    });
    c.setHeader('inputs', {
      for (final row in _inputs)
        if (row.name.text.trim().isNotEmpty)
          row.name.text.trim(): {
            'type': row.type,
            if (row.required) 'required': true,
            if (row.defaultValue.text.trim().isNotEmpty)
              'default': row.defaultValue.text.trim(),
          },
    });
    c.setHeader('roles', {
      for (final row in _roles)
        if (row.key.text.trim().isNotEmpty)
          row.key.text.trim(): {
            if (row.value.text.trim().isNotEmpty)
              'desc': row.value.text.trim(),
          },
    });
    c.setHeader('outputs', {
      for (final row in _outputs)
        if (row.key.text.trim().isNotEmpty)
          row.key.text.trim(): row.value.text.trim(),
    });
    Navigator.pop(context);
  }

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

class _PairRow {
  _PairRow(String key, String value)
      : key = TextEditingController(text: key),
        value = TextEditingController(text: value);

  final TextEditingController key;
  final TextEditingController value;

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
  })  : name = TextEditingController(text: name),
       defaultValue = TextEditingController(text: defaultText);

  final TextEditingController name;
  final TextEditingController defaultValue;
  String type;
  bool required;

  void dispose() {
    name.dispose();
    defaultValue.dispose();
  }
}
