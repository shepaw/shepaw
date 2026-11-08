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
  List<_InputRow> _inputs = [];
  List<_PairRow> _roles = [];
  List<_PairRow> _outputs = [];

  /// 打开时的原始头部映射。用来只发真正改过的字段，并保住表单没显示的键
  /// （roles.desc、inputs.default、limits 里的额外键、outputs 的非字符串值）。
  late String _rawDescription;
  late Map<String, dynamic> _rawLimits;
  late Map<String, dynamic> _rawInputs;
  late Map<String, dynamic> _rawRoles;
  late Map<String, dynamic> _rawOutputs;
  String _loadedYaml = '';
  int _applyGen = 0;
  bool _applying = false;
  bool _inputsBlocked = false;
  bool _rolesBlocked = false;
  bool _outputsBlocked = false;

  /// 表单里任何一个输入框有焦点时，不拿主机回包覆盖正在打的字。
  final FocusNode _formFocus = FocusNode(
    canRequestFocus: false,
    skipTraversal: true,
    descendantsAreFocusable: true,
  );

  @override
  void initState() {
    super.initState();
    _description = TextEditingController();
    _maxTasks = TextEditingController();
    _timeout = TextEditingController();
    _loadFrom(widget.controller.yaml);
    widget.controller.addListener(_onController);
    _formFocus.addListener(_onFormFocus);
  }

  void _onFormFocus() {
    if (!_formFocus.hasFocus) _flushNow();
  }

  void _onController() {
    if (!mounted || _applying || _formFocus.hasFocus) return;
    final yaml = widget.controller.yaml;
    if (yaml == _loadedYaml) return;
    setState(() => _loadFrom(yaml));
  }

  /// 用一份 YAML 重填表单。旧行的控制器等这一帧画完再丢掉，避免输入框
  /// 还指着已销毁的控制器。
  void _loadFrom(String yaml) {
    final previousInputs = List<_InputRow>.of(_inputs);
    final previousRoles = List<_PairRow>.of(_roles);
    final previousOutputs = List<_PairRow>.of(_outputs);
    _loadedYaml = yaml;
    _rawDescription = FlowHeaderPeek.description(yaml);
    _rawLimits = FlowHeaderPeek.raw(yaml, 'limits');
    _rawInputs = FlowHeaderPeek.raw(yaml, 'inputs');
    _rawRoles = FlowHeaderPeek.raw(yaml, 'roles');
    _rawOutputs = FlowHeaderPeek.raw(yaml, 'outputs');
    _description.text = _rawDescription;
    final maxTasks = (_rawLimits['max_tasks'] as num?)?.toInt() ?? 0;
    _maxTasks.text = maxTasks == 0 ? '' : maxTasks.toString();
    _timeout.text = _rawLimits['timeout']?.toString() ?? '';
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
    _inputsBlocked = false;
    _rolesBlocked = false;
    _outputsBlocked = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final row in previousInputs) {
        if (!_inputs.contains(row)) row.dispose();
      }
      for (final row in previousRoles) {
        if (!_roles.contains(row)) row.dispose();
      }
      for (final row in previousOutputs) {
        if (!_outputs.contains(row)) row.dispose();
      }
    });
  }

  Timer? _debounce;

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _formFocus.removeListener(_onFormFocus);
    _formFocus.dispose();
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
    _debounce = Timer(const Duration(milliseconds: 400), _flushNow);
  }

  /// 失焦或保存前立刻提交，不把最后一次编辑留在计时器里。
  void _flushNow() {
    _debounce?.cancel();
    unawaited(_apply());
  }

  /// 名称空着或撞了：这一组先不提交，避免改名改到一半把原参数删掉。
  /// 刚点「添加」、还没起名的草稿行不算。
  bool _namesBlocked(List<String> names) {
    if (names.any((name) => name.isEmpty)) return true;
    return names.toSet().length != names.length;
  }

  /// 五个字段合成**一个**原子批次。
  Future<void> _apply() async {
    if (widget.readOnly || !mounted) return;
    final gen = ++_applyGen;
    _applying = true;
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

    final inputNames = [
      for (final row in _inputs)
        if (!row.draft || row.name.text.trim().isNotEmpty) row.name.text.trim(),
    ];
    final inputsBlocked = _namesBlocked(inputNames);
    final encodedInputs = <String, dynamic>{
      for (final row in _inputs)
        if (row.name.text.trim().isNotEmpty)
          row.name.text.trim(): row.encode(),
    };
    if (!inputsBlocked && !_sameJson(_rawInputs, encodedInputs)) {
      next['inputs'] = encodedInputs;
    }

    final roleNames = [
      for (final row in _roles)
        if (!row.draft || row.key.text.trim().isNotEmpty) row.key.text.trim(),
    ];
    final rolesBlocked = _namesBlocked(roleNames);
    final encodedRoles = <String, dynamic>{
      for (final row in _roles)
        if (row.key.text.trim().isNotEmpty)
          row.key.text.trim(): row.encodeForRole(),
    };
    if (!rolesBlocked && !_sameJson(_rawRoles, encodedRoles)) {
      next['roles'] = encodedRoles;
    }

    final outputNames = [
      for (final row in _outputs)
        if (!row.draft || row.key.text.trim().isNotEmpty) row.key.text.trim(),
    ];
    final outputsBlocked = _namesBlocked(outputNames);
    final encodedOutputs = <String, dynamic>{
      for (final row in _outputs)
        if (row.key.text.trim().isNotEmpty)
          row.key.text.trim(): row.encodeForOutput(),
    };
    if (!outputsBlocked && !_sameJson(_rawOutputs, encodedOutputs)) {
      next['outputs'] = encodedOutputs;
    }

    if (inputsBlocked != _inputsBlocked ||
        rolesBlocked != _rolesBlocked ||
        outputsBlocked != _outputsBlocked) {
      setState(() {
        _inputsBlocked = inputsBlocked;
        _rolesBlocked = rolesBlocked;
        _outputsBlocked = outputsBlocked;
      });
    }

    if (next.isEmpty) {
      _applying = false;
      return;
    }
    try {
      final ok = await c.setHeaders(next);
      if (!ok || !mounted || gen != _applyGen) return;
    // 提交过程中又改过的字段不能把快照写成旧值，否则下一次会把新字盖掉。
    if (_description.text.trim() != description) return;
    _rawDescription = description;
    _rawLimits = encodedLimits;
    if (!inputsBlocked) _rawInputs = encodedInputs;
    if (!rolesBlocked) _rawRoles = encodedRoles;
      if (!outputsBlocked) _rawOutputs = encodedOutputs;
      _loadedYaml = c.yaml;
    } finally {
      if (gen == _applyGen) _applying = false;
    }
  }

  bool _sameJson(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Focus(
      focusNode: _formFocus,
      canRequestFocus: false,
      skipTraversal: true,
      child: Column(
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
                  onEditingComplete: _flushNow,
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
                        onEditingComplete: _flushNow,
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
                        onEditingComplete: _flushNow,
                      ),
                    ),
                  ],
                ),
              ]),
              _section(l10n.flow_headerInputs, [
                if (_inputsBlocked)
                  Text(l10n.flow_headerNamesBlocked,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.error)),
                for (final row in _inputs) _inputRow(row, l10n),
                _addRow(l10n.flow_headerAddInput, () => setState(() {
                      _inputs.add(_InputRow(name: '', type: 'string', draft: true));
                    })),
              ]),
              _section(l10n.flow_headerRoles, [
                if (_rolesBlocked)
                  Text(l10n.flow_headerNamesBlocked,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.error)),
                for (final row in _roles)
                  _pairRow(row, l10n.flow_headerRoleName,
                      l10n.flow_headerRoleDesc),
                _addRow(l10n.flow_headerAddRole, () => setState(
                    () => _roles.add(_PairRow('', '', draft: true)))),
              ]),
              _section(l10n.flow_headerOutputs, [
                if (_outputsBlocked)
                  Text(l10n.flow_headerNamesBlocked,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.error)),
                for (final row in _outputs)
                  _pairRow(row, l10n.flow_headerOutputName,
                      l10n.flow_headerOutputTemplate),
                _addRow(l10n.flow_headerAddOutput, () => setState(
                    () => _outputs.add(_PairRow('', '', draft: true)))),
              ]),
            ],
          ),
        ),
      ],
      ),
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
              readOnly: widget.readOnly,
              decoration:
                  InputDecoration(labelText: keyLabel, isDense: true),
              onChanged: (_) => _schedule(),
              onEditingComplete: _flushNow,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: row.value,
              readOnly: widget.readOnly,
              decoration:
                  InputDecoration(labelText: valueLabel, isDense: true),
              onChanged: (_) => _schedule(),
              onEditingComplete: _flushNow,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: widget.readOnly
                ? null
                : () => setState(() {
                      row.draft = false;
                      _roles.remove(row);
                      _outputs.remove(row);
                      row.dispose();
                      _schedule();
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
                      readOnly: widget.readOnly,
                      decoration: InputDecoration(
                          labelText: l10n.flow_headerInputName,
                          isDense: true),
                      onChanged: (_) => _schedule(),
                      onEditingComplete: _flushNow,
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
                    onPressed: widget.readOnly
                        ? null
                        : () => setState(() {
                              row.draft = false;
                              _inputs.remove(row);
                              row.dispose();
                              _schedule();
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
                      readOnly: widget.readOnly,
                      decoration: InputDecoration(
                          labelText: l10n.flow_headerInputDefault,
                          isDense: true),
                      onChanged: (_) => _schedule(),
                      onEditingComplete: _flushNow,
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
  _PairRow(String key, String value, {this.original, this.draft = false})
      : key = TextEditingController(text: key),
        value = TextEditingController(text: value);

  /// 刚加出来、还没起名的行。空名称不参与「不能提交」的判断。
  bool draft = false;

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
    this.draft = false,
    String defaultText = '',
    this.original,
  })  : name = TextEditingController(text: name),
       defaultValue = TextEditingController(text: defaultText);

  /// 刚加出来、还没起名的行。
  bool draft = false;

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
