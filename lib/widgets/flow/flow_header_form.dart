import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../controllers/flow/flow_editor_controller.dart';
import '../../controllers/flow/flow_executor.dart';
import '../../controllers/flow/flow_names.dart';
import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_models.dart';
import '../../screens/flow_start_screen.dart';
import '../discard_changes_scope.dart';

/// 流程设置：嵌在属性面板里，改动直接 `setHeaders`，没有「应用」按钮。
class FlowHeaderForm extends StatefulWidget {
  const FlowHeaderForm({
    super.key,
    required this.controller,
    this.readOnly = false,
    this.onPickAgent,
    this.onPreviewStart,
    this.agentLabel,
    this.tree = const [],
    this.onBlocked,
  });

  final FlowEditorController controller;
  final bool readOnly;
  final Future<String?> Function()? onPickAgent;

  /// 把开跑预览放到工作流右侧，而不是再推一个全屏路由。
  final Future<void> Function({
    required List<FlowInputSpec> inputSpecs,
    required List<String> roles,
    required Map<String, String> roleDefaults,
  })? onPreviewStart;

  /// 把存下来的 Hub agent id 换成界面上的名字。没有就显示 id。
  final String? Function(String id)? agentLabel;
  final List<FlowNode> tree;

  /// 名称或运行限制还不合法，这一组没有提交。保存和演练要停下来。
  final ValueChanged<bool>? onBlocked;

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
  bool _limitsBlocked = false;
  bool _formFocused = false;
  bool _renaming = false;

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
    final focused = _formFocus.hasFocus;
    final wasFocused = _formFocused;
    _formFocused = focused;
    // 只有真正从输入框离开才提交。焦点节点挂上时也会通知一次「没有焦点」，
    // 那一次不能把表单里的旧值再发一遍。
    if (wasFocused && !focused) _flushNow();
  }

  /// 流程名是库里的名字，不能只改定义头。对话框里校验，确认后交给控制器换名。
  Future<void> _rename() async {
    if (widget.readOnly || _renaming) return;
    final l10n = AppLocalizations.of(context);
    final current = widget.controller.name;
    final field = TextEditingController(text: current);
    final formKey = GlobalKey<FormState>();
    final next = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.flow_renameTitle),
        content: Form(
          key: formKey,
          child: TextFormField(
            key: const ValueKey('flow-rename-name'),
            controller: field,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.flow_newName,
              hintText: l10n.flow_newNameHint,
            ),
            validator: (value) {
              final problem = FlowNameRules.check(value?.trim() ?? '');
              return switch (problem) {
                null => null,
                FlowNameProblem.reserved => l10n.flow_newNameReserved,
                FlowNameProblem.empty ||
                FlowNameProblem.invalid =>
                  l10n.flow_newNameInvalid,
              };
            },
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(dialog, field.text.trim());
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            key: const ValueKey('flow-rename-go'),
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(dialog, field.text.trim());
              }
            },
            child: Text(l10n.flow_renameAction),
          ),
        ],
      ),
    );
    field.dispose();
    if (next == null || next == current || !mounted) return;
    setState(() => _renaming = true);
    try {
      await widget.controller.rename(next);
    } finally {
      if (mounted) setState(() => _renaming = false);
    }
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
    _limitsBlocked = false;
    widget.onBlocked?.call(false);
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
    widget.onBlocked?.call(false);
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
    final maxRaw = _maxTasks.text.trim();
    final maxTasks = int.tryParse(maxRaw);
    // 「2a」不是数字。以前会当成 0，把已经保存的上限删掉。
    final maxInvalid = maxRaw.isNotEmpty && maxTasks == null;
    if (!maxInvalid) {
      if (maxTasks != null && maxTasks > 0) {
        encodedLimits['max_tasks'] = maxTasks;
      } else {
        encodedLimits.remove('max_tasks');
      }
    }
    final timeout = _timeout.text.trim();
    final previousTimeout = _rawLimits['timeout']?.toString() ?? '';
    final timeoutOk = timeout.isEmpty ||
        timeout == previousTimeout ||
        RegExp(r'^\d+\s*[smh]$').hasMatch(timeout);
    if (timeoutOk) {
      if (timeout.isNotEmpty) {
        encodedLimits['timeout'] = timeout;
      } else {
        encodedLimits.remove('timeout');
      }
    }
    final limitsBlocked = maxInvalid || !timeoutOk;
    if (!limitsBlocked && !_sameJson(_rawLimits, encodedLimits)) {
      next['limits'] = encodedLimits;
    }

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

    final blocked =
        inputsBlocked || rolesBlocked || outputsBlocked || limitsBlocked;
    widget.onBlocked?.call(blocked);
    if (inputsBlocked != _inputsBlocked ||
        rolesBlocked != _rolesBlocked ||
        outputsBlocked != _outputsBlocked ||
        limitsBlocked != _limitsBlocked) {
      setState(() {
        _inputsBlocked = inputsBlocked;
        _rolesBlocked = rolesBlocked;
        _outputsBlocked = outputsBlocked;
        _limitsBlocked = limitsBlocked;
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
    if (!limitsBlocked) _rawLimits = encodedLimits;
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.controller.name,
                  key: const ValueKey('flow-name'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (!widget.readOnly)
                TextButton.icon(
                  key: const ValueKey('flow-rename'),
                  onPressed: _renaming ? null : _rename,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: Text(l10n.flow_renameAction),
                ),
            ],
          ),
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
              ]),
              _section(l10n.flow_headerInputs, [
                Text(l10n.flow_headerInputsHint,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                if (_inputsBlocked)
                  Text(l10n.flow_headerNamesBlocked,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.error)),
                for (var i = 0; i < _inputs.length; i++)
                  _inputCard(i, l10n),
                _addRow(l10n.flow_headerAddInput, () {
                  final row = _InputRow(
                    name: '',
                    type: 'string',
                    draft: true,
                    expanded: true,
                  );
                  setState(() => _inputs.add(row));
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) row.nameFocus.requestFocus();
                  });
                }),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('header-preview-start'),
                    onPressed: _previewStart,
                    child: Text(l10n.flow_headerPreviewStart),
                  ),
                ),
              ]),
              _section(l10n.flow_headerRoles, [
                if (_rolesBlocked)
                  Text(l10n.flow_headerNamesBlocked,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.error)),
                for (var i = 0; i < _roles.length; i++) _roleCard(i, l10n),
                _addRow(l10n.flow_headerAddRole, () {
                  final row = _PairRow('', '', draft: true, expanded: true);
                  setState(() => _roles.add(row));
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) row.nameFocus.requestFocus();
                  });
                }),
              ]),
              _limitsSection(l10n, theme),
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

  Widget _pairRow(
    _PairRow row,
    String keyLabel,
    String valueLabel, {
    Future<void> Function()? onDelete,
  }) => Row(
        children: [
          Expanded(
            child: TextField(
              controller: row.key,
              focusNode: row.nameFocus,
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
                : () {
                    if (onDelete != null) {
                      unawaited(onDelete());
                      return;
                    }
                    setState(() {
                      row.draft = false;
                      _roles.remove(row);
                      _outputs.remove(row);
                    });
                    _schedule();
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => row.dispose());
                  },
          ),
        ],
      );

  String _agentName(String id) {
    if (id.isEmpty) return '';
    final label = widget.agentLabel?.call(id)?.trim();
    if (label == null || label.isEmpty) return id;
    return label;
  }

  Map<String, List<String>> get _inputUsers =>
      FlowHeaderUsage.inputs(widget.tree);

  Map<String, List<String>> get _roleUsers =>
      FlowHeaderUsage.roles(widget.tree);

  Future<void> _previewStart() {
    final specs = [
      for (final row in _inputs)
        if (row.name.text.trim().isNotEmpty)
          FlowInputSpec(
            name: row.name.text.trim(),
            type: row.type,
            required: row.required,
            defaultValue: row.defaultValue.text.trim().isEmpty
                ? null
                : row.defaultValue.text.trim(),
          ),
    ];
    final roles = [
      for (final row in _roles)
        if (row.key.text.trim().isNotEmpty) row.key.text.trim(),
    ];
    final defaults = {
      for (final row in _roles)
        if (row.key.text.trim().isNotEmpty &&
            (row.agentDefault?.isNotEmpty ?? false))
          row.key.text.trim(): row.agentDefault!,
    };
    if (widget.onPreviewStart != null) {
      return widget.onPreviewStart!(
        inputSpecs: specs,
        roles: roles,
        roleDefaults: defaults,
      );
    }
    return pushFlowStartScreen(
      context,
      flowName: widget.controller.name,
      yaml: widget.controller.yaml,
      roles: roles,
      roleDefaults: defaults,
      inputSpecs: specs,
      dirty: false,
      scope: widget.controller.scope,
      revision: widget.controller.revision,
      onPickAgent: widget.onPickAgent,
      preview: true,
    );
  }

  Future<bool> _confirmDrop(String name, List<String> users) async {
    if (name.isEmpty || users.isEmpty) return true;
    final l10n = AppLocalizations.of(context);
    final ok = await showConfirmDialog(
      context,
      title: l10n.common_delete,
      message: l10n.flow_headerDeleteRefs(users.join(', ')),
      confirmLabel: l10n.common_delete,
    );
    return ok == true;
  }

  void _moveInput(int index, int delta) {
    final next = index + delta;
    if (next < 0 || next >= _inputs.length) return;
    setState(() {
      final row = _inputs.removeAt(index);
      _inputs.insert(next, row);
    });
    _schedule();
  }

  void _moveRole(int index, int delta) {
    final next = index + delta;
    if (next < 0 || next >= _roles.length) return;
    setState(() {
      final row = _roles.removeAt(index);
      _roles.insert(next, row);
    });
    _schedule();
  }

  Widget _rowMenu({
    required int index,
    required int length,
    required void Function(String action) onSelected,
  }) {
    final l10n = AppLocalizations.of(context);
    return PopupMenuButton<String>(
      enabled: !widget.readOnly,
      onSelected: onSelected,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'up',
          enabled: index > 0,
          child: Text(l10n.flow_outlineMoveUp),
        ),
        PopupMenuItem(
          value: 'down',
          enabled: index < length - 1,
          child: Text(l10n.flow_outlineMoveDown),
        ),
        PopupMenuItem(value: 'delete', child: Text(l10n.common_delete)),
      ],
    );
  }

  bool _inputNameBad(_InputRow row) {
    final name = row.name.text.trim();
    if (row.draft && name.isEmpty) return false;
    if (name.isEmpty) return true;
    final same = [
      for (final other in _inputs)
        if (!other.draft || other.name.text.trim().isNotEmpty)
          other.name.text.trim(),
    ].where((item) => item == name);
    return same.length > 1;
  }

  bool _roleNameBad(_PairRow row) {
    final name = row.key.text.trim();
    if (row.draft && name.isEmpty) return false;
    if (name.isEmpty) return true;
    final same = [
      for (final other in _roles)
        if (!other.draft || other.key.text.trim().isNotEmpty)
          other.key.text.trim(),
    ].where((item) => item == name);
    return same.length > 1;
  }

  Widget _inputCard(int index, AppLocalizations l10n) {
    final row = _inputs[index];
    final name = row.name.text.trim();
    final users = _inputUsers[name] ?? const <String>[];
    final summary = name.isEmpty
        ? l10n.flow_headerAddInput
        : '$name · ${_inputTypeLabel(l10n, row.type)}'
            '${row.required ? ' · ${l10n.flow_inputRequiredShort}' : ''}';
    return Card(
      color: _inputNameBad(row)
          ? Theme.of(context).colorScheme.errorContainer
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            dense: true,
            title: Text(summary),
            subtitle: users.isEmpty
                ? null
                : Text(l10n.flow_headerUsedBy(users.length, users.join(', '))),
            trailing: _rowMenu(
              index: index,
              length: _inputs.length,
              onSelected: (action) async {
                switch (action) {
                  case 'up':
                    _moveInput(index, -1);
                  case 'down':
                    _moveInput(index, 1);
                  case 'delete':
                    if (!await _confirmDrop(name, users) || !mounted) return;
                    setState(() {
                      row.draft = false;
                      _inputs.remove(row);
                    });
                    _schedule();
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => row.dispose());
                }
              },
            ),
            onTap: () => setState(() => row.expanded = !row.expanded),
          ),
          if (row.expanded) _inputFields(row, l10n),
        ],
      ),
    );
  }

  Widget _roleCard(int index, AppLocalizations l10n) {
    final row = _roles[index];
    final name = row.key.text.trim();
    final users = _roleUsers[name] ?? const <String>[];
    final agent = row.agentDefault?.trim() ?? '';
    final agentName = _agentName(agent);
    final summary = name.isEmpty
        ? l10n.flow_headerAddRole
        : agentName.isEmpty
            ? name
            : '$name · $agentName';
    return Card(
      color: _roleNameBad(row)
          ? Theme.of(context).colorScheme.errorContainer
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            dense: true,
            title: Text(summary),
            subtitle: users.isEmpty
                ? null
                : Text(
                    l10n.flow_headerRoleUsedBy(users.length, users.join(', '))),
            trailing: _rowMenu(
              index: index,
              length: _roles.length,
              onSelected: (action) async {
                switch (action) {
                  case 'up':
                    _moveRole(index, -1);
                  case 'down':
                    _moveRole(index, 1);
                  case 'delete':
                    if (!await _confirmDrop(name, users) || !mounted) return;
                    setState(() {
                      row.draft = false;
                      _roles.remove(row);
                    });
                    _schedule();
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => row.dispose());
                }
              },
            ),
            onTap: () => setState(() => row.expanded = !row.expanded),
          ),
          if (row.expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _pairRow(
                    row,
                    l10n.flow_headerRoleName,
                    l10n.flow_headerRoleDesc,
                    onDelete: () async {
                      if (!await _confirmDrop(name, users) || !mounted) return;
                      setState(() {
                        row.draft = false;
                        _roles.remove(row);
                      });
                      _schedule();
                      WidgetsBinding.instance
                          .addPostFrameCallback((_) => row.dispose());
                    },
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: widget.readOnly ||
                                  widget.onPickAgent == null
                              ? null
                              : () async {
                                  final picked =
                                      await widget.onPickAgent!.call();
                                  if (picked == null || !mounted) return;
                                  setState(() => row.agentDefault = picked);
                                  _schedule();
                                },
                          child: Text(
                            agentName.isEmpty
                                ? l10n.flow_headerRoleDefault
                                : agentName,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (agent.isNotEmpty)
                        TextButton(
                          onPressed: widget.readOnly
                              ? null
                              : () {
                                  setState(() => row.agentDefault = '');
                                  _schedule();
                                },
                          child: Text(l10n.flow_headerClearDefault),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _limitsSection(AppLocalizations l10n, ThemeData theme) {
    final tasks = _maxTasks.text.trim();
    final timeout = _timeout.text.trim();
    final summary =
        '${tasks.isEmpty ? l10n.flow_headerNoLimit : tasks} · ${timeout.isEmpty ? l10n.flow_headerNoLimit : timeout}';
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text(l10n.flow_headerLimitsTitle),
      subtitle: Text(summary, style: theme.textTheme.bodySmall),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _maxTasks,
                readOnly: widget.readOnly,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: l10n.flow_headerMaxTasks, isDense: true),
                onChanged: (_) => _schedule(),
                onEditingComplete: _flushNow,
              ),
              const SizedBox(height: 8),
              _timeoutEditor(l10n),
              if (_limitsBlocked)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    l10n.flow_headerLimitsBlocked,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _timeoutEditor(AppLocalizations l10n) {
    final match =
        RegExp(r'^(\d+)\s*([smh])$').firstMatch(_timeout.text.trim());
    final legacy = _timeout.text.trim().isNotEmpty && match == null;
    if (legacy) {
      return TextField(
        controller: _timeout,
        readOnly: widget.readOnly,
        decoration: InputDecoration(
            labelText: l10n.flow_headerTimeout, hintText: '2h', isDense: true),
        onChanged: (_) => _schedule(),
        onEditingComplete: _flushNow,
      );
    }
    final amount = match?.group(1) ?? '';
    final unit = match?.group(2) ?? 's';
    String label(String value) => switch (value) {
          'm' => l10n.flow_durationMinutes,
          'h' => l10n.flow_durationHours,
          _ => l10n.flow_durationSeconds,
        };
    return Row(
      children: [
        Expanded(
          child: TextFormField(
            key: ValueKey('header-timeout-$amount-$unit'),
            initialValue: amount,
            readOnly: widget.readOnly,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: l10n.flow_headerTimeout, isDense: true),
            onChanged: (text) {
              final raw = text.trim();
              final n = int.tryParse(raw);
              _timeout.text =
                  raw.isEmpty ? '' : (n != null && n > 0 ? '$n$unit' : raw);
              _schedule();
            },
            onEditingComplete: _flushNow,
          ),
        ),
        const SizedBox(width: 8),
        DropdownButton<String>(
          value: unit,
          items: [
            for (final value in ['s', 'm', 'h'])
              DropdownMenuItem(value: value, child: Text(label(value))),
          ],
          onChanged: widget.readOnly
              ? null
              : (value) {
                  if (value == null) return;
                  final n = int.tryParse(amount);
                  setState(() {
                    _timeout.text =
                        n != null && n > 0 ? '$n$value' : amount;
                  });
                  _schedule();
                },
        ),
      ],
    );
  }

  Widget _inputFields(_InputRow row, AppLocalizations l10n) => Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: row.name,
                      focusNode: row.nameFocus,
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
                        for (final type in _inputTypeChoices(row.type))
                          DropdownMenuItem<String>(
                            value: type,
                            child: Text(_inputTypeLabel(l10n, type)),
                          ),
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
                        : () {
                            setState(() {
                              row.draft = false;
                              _inputs.remove(row);
                            });
                            _schedule();
                            WidgetsBinding.instance
                                .addPostFrameCallback((_) => row.dispose());
                          },
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
        );
}

/// roles / outputs 的一行。`original` 留住原始值，没编辑过的行原样写回，
/// 免得把 `desc`、额外键、非字符串值抹掉。
class _PairRow {
  _PairRow(
    String key,
    String value, {
    this.original,
    this.draft = false,
    this.expanded = false,
    this.agentDefault,
  })  : key = TextEditingController(text: key),
        value = TextEditingController(text: value),
        nameFocus = FocusNode();

  /// 刚加出来、还没起名的行。空名称不参与「不能提交」的判断。
  bool draft = false;
  bool expanded;

  /// 角色的默认执行者。空字符串表示用户清掉了。
  String? agentDefault;

  _PairRow.from(String key, Object? raw)
      : original = raw,
        expanded = false,
        agentDefault = raw is Map ? raw['default']?.toString() : null,
        key = TextEditingController(text: key),
        value = TextEditingController(text: _display(raw)),
        nameFocus = FocusNode();

  _PairRow.forRole(String key, Object? raw)
      : original = raw,
        expanded = false,
        agentDefault = raw is Map ? raw['default']?.toString() : null,
        key = TextEditingController(text: key),
        value = TextEditingController(
          text: raw is Map ? (raw['desc']?.toString() ?? '') : '',
        ),
        nameFocus = FocusNode();

  final TextEditingController key;
  final TextEditingController value;
  final FocusNode nameFocus;
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
    final agent = agentDefault?.trim() ?? '';
    if (agent.isEmpty) {
      out.remove('default');
    } else {
      out['default'] = agent;
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
    nameFocus.dispose();
  }
}

const _knownInputTypes = ['string', 'int', 'bool', 'list'];

List<String> _inputTypeChoices(String type) => [
      ..._knownInputTypes,
      if (!_knownInputTypes.contains(type)) type,
    ];

class _InputRow {
  _InputRow({
    required String name,
    required this.type,
    this.required = false,
    this.draft = false,
    this.expanded = false,
    String defaultText = '',
    this.original,
  })  : name = TextEditingController(text: name),
        defaultValue = TextEditingController(text: defaultText),
        nameFocus = FocusNode();

  /// 刚加出来、还没起名的行。
  bool draft = false;
  bool expanded;

  _InputRow.from(String key, Object? raw)
      : original = raw is Map ? Map<String, dynamic>.from(raw) : null,
        type = _typeOf(raw),
        required = raw is Map && raw['required'] == true,
        expanded = false,
        name = TextEditingController(text: key),
        defaultValue = TextEditingController(
          text: raw is Map ? raw['default']?.toString() ?? '' : '',
        ),
        nameFocus = FocusNode();

  final TextEditingController name;
  final TextEditingController defaultValue;
  final FocusNode nameFocus;
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
    final text = defaultValue.text.trim();
    if (text.isEmpty) {
      out.remove('default');
    } else {
      // 没改过的 bool / 列表要原样写回。这里若压成字符串，
      // 改一下简介就会把整个 inputs 带出去，默认值类型就变了。
      out['default'] =
          flowInputDefaultForForm(original?['default'], text, type);
    }
    return out;
  }

  static String _typeOf(Object? raw) {
    final type = raw is Map ? (raw['type']?.toString().trim() ?? '') : '';
    if (type.isEmpty) return 'string';
    // 主机把 array 当成 list 的别名。下拉里没有 array，会直接断言。
    if (type == 'array') return 'list';
    return type;
  }

  void dispose() {
    name.dispose();
    defaultValue.dispose();
    nameFocus.dispose();
  }
}

String _inputTypeLabel(AppLocalizations l10n, String type) => switch (type) {
      'int' => l10n.flow_headerTypeInt,
      'bool' => l10n.flow_headerTypeBool,
      'list' => l10n.flow_headerTypeList,
      'string' => l10n.flow_headerTypeString,
      _ => type,
    };
