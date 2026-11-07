import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/flow/flow_executor.dart';
import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_field_schema.dart';

/// 「跟随 agent 默认」这一项的值。用一个不会和真实模型 / 模式 id 撞上的哨兵。
const String _kFollowDefault = '\u0000follow-agent-default';

/// `modelRef` / `modeRef` 下拉里的一项。`value` 是写进字段的值（主机只认 id），
/// `displayName` / `description` 只拿来显示。
class FlowModelChoice {
  const FlowModelChoice({
    required this.value,
    this.displayName,
    this.description = '',
  });

  final String value;
  final String? displayName;
  final String description;

  String get label =>
      (displayName == null || displayName!.isEmpty) ? value : displayName!;
}

/// 一个 `modelRef` / `modeRef` 字段的可选项与状态（由检查器异步填好）。
class FlowModelChoices {
  const FlowModelChoices({
    this.options = const [],
    this.current,
    this.switchable = true,
    this.loading = false,
    this.hint,
    this.allowManual = false,
  });

  final List<FlowModelChoice> options;

  /// 该 agent 当前的默认模型 / 模式（显示在「跟随默认」那一项里）。
  final String? current;

  /// false：模型在远端配置，App 只能展示不能切换。
  final bool switchable;
  final bool loading;

  /// 说明性提示（role 模式「运行时按绑定决定」、加载失败等）。
  final String? hint;

  /// 没有固定 agent（role / unset）时允许手输模板变量。
  final bool allowManual;

  static const empty = FlowModelChoices();

  bool get canPick => switchable && options.isNotEmpty;
}

/// 一次拉取得到的两个字段候选（model 与 mode 一起刷）。
class FlowChoiceBundle {
  const FlowChoiceBundle({
    this.models = FlowModelChoices.empty,
    this.modes = FlowModelChoices.empty,
  });

  final FlowModelChoices models;
  final FlowModelChoices modes;

  static const empty = FlowChoiceBundle();
}

/// 拉候选：先回缓存（[onCached]），再回最终刷新结果。生产实现见
/// [defaultFlowChoiceLoader]；测试里换成假的即可，不必碰数据库和主机。
typedef FlowChoiceLoader = Future<FlowChoiceBundle> Function(
  FlowExecutor executor, {
  required String peerId,
  required Map<String, dynamic> roles,
  required void Function(FlowChoiceBundle cached) onCached,
});

/// 一个字段的编辑器。
///
/// 按 [FlowFieldSpec.shape] 选控件，产出主机 `set` 操作能直接吃的值。空值一律
/// 回 null（= 删掉这个键）；必填字段清空时标红并回 null 之外不发坏值 —— 由调用
/// 方决定要不要拦。
class FlowFieldEditor extends StatefulWidget {
  const FlowFieldEditor({
    super.key,
    required this.spec,
    required this.current,
    required this.onChanged,
    this.refCandidates = const [],
    this.intInputNames = const [],
    this.flowRefChoices = const [],
    this.choices,
  });

  final FlowFieldSpec spec;
  final Object? current;
  final void Function(Object? value) onChanged;

  /// string / text 的「插入引用」候选。
  final List<String> refCandidates;

  /// [FlowFieldShape.intOrInput] 能引用的 int 输入名。
  final List<String> intInputNames;

  /// [FlowFieldShape.flowRef] 的候选（`lib/<name>` / `group/<gid>/<name>`）。
  final List<String> flowRefChoices;

  /// [FlowFieldShape.modelRef] / [FlowFieldShape.modeRef] 的候选与状态。
  final FlowModelChoices? choices;

  @override
  State<FlowFieldEditor> createState() => _FlowFieldEditorState();
}

class _FlowFieldEditorState extends State<FlowFieldEditor> {
  late final TextEditingController _scalar;
  late final TextEditingController _judge;
  late final TextEditingController _ask;
  late String _enumValue;
  bool? _boolean;
  bool _condIsJudge = false;
  bool _manualChoice = false;
  late String _choiceValue;
  late List<TextEditingController> _list;
  late List<_Pair> _pairs;
  late List<_OutputRow> _outputs;

  @override
  void initState() {
    super.initState();
    _seed();
  }

  /// 调用方换了节点 / 主机推来了新草稿时由**值派生的 key**触发重建，重新播种
  /// 输入框（见 [FlowNodeInspector] 里的 `field-…` key）。这里不做 didUpdateWidget
  /// 里 dispose + 重建控制器 —— 那会在 TextField 还持有焦点时打断
  /// `_FocusInheritedScope`。
  void _seed() {
    final c = widget.current;
    _scalar = TextEditingController(
      text: c is num ? c.toString() : (c is String ? c : ''),
    );
    final cond = c is Map ? c : null;
    _condIsJudge = cond != null && cond.containsKey('judge');
    _judge = TextEditingController(text: cond?['judge']?.toString() ?? '');
    _ask = TextEditingController(text: cond?['ask']?.toString() ?? '');
    _enumValue =
        widget.spec.options.contains(c?.toString()) ? c!.toString() : '';
    _boolean = c is bool ? c : null;
    // 模板值（`{{ inputs.model }}`）走文本模式；其余用下拉，空值 = 跟随默认。
    final raw = c is String ? c : '';
    _manualChoice = raw.trimLeft().startsWith('{{');
    _choiceValue = (_manualChoice || raw.isEmpty) ? _kFollowDefault : raw;
    _list = [
      if (c is List)
        for (final item in c) TextEditingController(text: item.toString()),
    ];
    if (_list.isEmpty && widget.spec.shape == FlowFieldShape.listOf) {
      _list.add(TextEditingController());
    }
    _pairs = [
      if (c is Map)
        for (final entry in c.entries)
          _Pair(entry.key.toString(), entry.value?.toString() ?? ''),
    ];
    if (_pairs.isEmpty && widget.spec.shape == FlowFieldShape.mapOf) {
      _pairs.add(_Pair('', ''));
    }
    _outputs = [
      if (c is Map)
        for (final entry in c.entries) _OutputRow.from(entry.key, entry.value),
    ];
    if (_outputs.isEmpty && widget.spec.shape == FlowFieldShape.outputMap) {
      _outputs.add(_OutputRow(''));
    }
  }

  void _releaseControllers() {
    _scalar.dispose();
    _judge.dispose();
    _ask.dispose();
    for (final c in _list) {
      c.dispose();
    }
    for (final p in _pairs) {
      p.dispose();
    }
    for (final row in _outputs) {
      row.dispose();
    }
  }

  @override
  void dispose() {
    _releaseControllers();
    super.dispose();
  }

  void _emit() {
    final shape = widget.spec.shape;
    Object? value;
    switch (shape) {
      case FlowFieldShape.string:
      case FlowFieldShape.text:
        value = _scalar.text.trim().isEmpty ? null : _scalar.text;
      case FlowFieldShape.int:
        // 非数字绝不发出去：主机 M1.5 会因解析失败拒掉**整批**，连带把一起改的
        // 其他字段全标成 rejected。改成不发（界面标红）。
        value = _numberOrNull(_scalar.text.trim());
      case FlowFieldShape.intOrInput:
        // 数字写成 int；引用写成 "{{ inputs.x }}"；别的都不发。
        value = _intOrInputOrNull(_scalar.text.trim());
      case FlowFieldShape.boolean:
        value = _boolean;
      case FlowFieldShape.enumOf:
        value = _enumValue.isEmpty ? null : _enumValue;
      case FlowFieldShape.cond:
        if (_condIsJudge) {
          final judge = _judge.text.trim();
          final ask = _ask.text.trim();
          value = (judge.isEmpty && ask.isEmpty)
              ? null
              : {'judge': judge, 'ask': ask};
        } else {
          value = _scalar.text.trim().isEmpty ? null : _scalar.text.trim();
        }
      case FlowFieldShape.listOf:
        final items = [
          for (final c in _list)
            if (c.text.trim().isNotEmpty) c.text.trim(),
        ];
        value = items.isEmpty ? null : items;
      case FlowFieldShape.mapOf:
        final map = <String, String>{
          for (final p in _pairs)
            if (p.key.text.trim().isNotEmpty)
              p.key.text.trim(): p.value.text.trim(),
        };
        value = map.isEmpty ? null : map;
      case FlowFieldShape.outputMap:
        final map = <String, Object>{
          for (final row in _outputs)
            if (row.key.text.trim().isNotEmpty)
              row.key.text.trim(): row.encode(),
        };
        value = map.isEmpty ? null : map;
      case FlowFieldShape.flowRef:
        value = _scalar.text.trim().isEmpty ? null : _scalar.text.trim();
      case FlowFieldShape.modelRef:
      case FlowFieldShape.modeRef:
        if (_manualChoice) {
          // A8-8：不可切换的 agent 上，模板值只能原样展示。即便用户之前在
          // 可切换状态下进过文本模式，也不再把编辑后的值发出去覆盖远程配置。
          final locked =
              widget.choices?.switchable == false ? widget.current : null;
          value = locked is String
              ? (locked.isEmpty ? null : locked)
              : (_scalar.text.trim().isEmpty ? null : _scalar.text.trim());
        } else {
          value = _choiceValue == _kFollowDefault ? null : _choiceValue;
        }
    }
    widget.onChanged(value);
  }

  static int? _numberOrNull(String raw) {
    if (raw.isEmpty) return null;
    return int.tryParse(raw);
  }

  static Object? _intOrInputOrNull(String raw) {
    if (raw.isEmpty) return null;
    final n = int.tryParse(raw);
    if (n != null) return n;
    if (RegExp(r'^\{\{\s*inputs\.[A-Za-z0-9_.-]+\s*\}\}$').hasMatch(raw)) {
      return raw;
    }
    return null;
  }

  /// 插入引用到光标处。
  void _insertRef(String ref) {
    final at = _scalar.selection.baseOffset.clamp(0, _scalar.text.length);
    _scalar.value = _scalar.value.copyWith(
      text: _scalar.text.substring(0, at) + ref + _scalar.text.substring(at),
      selection: TextSelection.collapsed(offset: at + ref.length),
    );
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final spec = widget.spec;
    final label = spec.label(zh);
    final emptyRequired = spec.required && _isEmptyValue();

    Widget wrap(Widget child) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label + (spec.required ? ' *' : ''),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: emptyRequired
                          ? scheme.error
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            child,
            if (emptyRequired)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l10n.flow_fieldRequired,
                  style:
                      theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
          ],
        );

    final textDecoration = InputDecoration(
      isDense: true,
      border: const OutlineInputBorder(),
      suffixIcon: widget.refCandidates.isEmpty
          ? null
          : IconButton(
              key: ValueKey('ref:${spec.path}'),
              tooltip: l10n.flow_refInsert,
              icon: const Icon(Icons.data_object, size: 18),
              onPressed: () => unawaited(_pickRef(context)),
            ),
    );

    return switch (spec.shape) {
      // 长文本（task.prompt / plan.brief …）随内容自动长高，不再钉死五行。
      FlowFieldShape.text => wrap(TextField(
          key: ValueKey('f:${spec.path}'),
          controller: _scalar,
          minLines: 3,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          decoration: textDecoration,
          onChanged: (_) => setState(_emit),
        )),
      // string 是 id / 短标量（task.uses、call.group、plan.who …），必须单行：
      // 放开多行会把换行原样发给主机，`agent:<id>\n` 就解析不出 Agent 了。
      FlowFieldShape.string => wrap(TextField(
          key: ValueKey('f:${spec.path}'),
          controller: _scalar,
          maxLines: 1,
          decoration: textDecoration,
          onChanged: (_) => setState(_emit),
        )),
      FlowFieldShape.int => wrap(TextField(
          key: ValueKey('f:${spec.path}'),
          controller: _scalar,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(isDense: true),
          onChanged: (_) => setState(_emit),
        )),
      FlowFieldShape.intOrInput => wrap(Row(
          children: [
            Expanded(
              child: TextField(
                key: ValueKey('f:${spec.path}'),
                controller: _scalar,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(isDense: true),
                onChanged: (_) => setState(_emit),
              ),
            ),
            if (widget.intInputNames.isNotEmpty)
              PopupMenuButton<String>(
                key: ValueKey('int-input:${spec.path}'),
                tooltip: l10n.flow_fieldPickInput,
                icon: const Icon(Icons.alternate_email, size: 18),
                onSelected: (name) => setState(() {
                  _scalar.text = '{{ inputs.$name }}';
                  _emit();
                }),
                itemBuilder: (_) => [
                  for (final name in widget.intInputNames)
                    PopupMenuItem<String>(
                        value: name, child: Text('inputs.$name')),
                ],
              ),
          ],
        )),
      FlowFieldShape.boolean => wrap(DropdownButtonFormField<String>(
          key: ValueKey('f:${spec.path}'),
          initialValue: _boolean == null ? '' : _boolean.toString(),
          isDense: true,
          items: const [
            DropdownMenuItem<String>(value: '', child: Text('—')),
            DropdownMenuItem<String>(value: 'true', child: Text('true')),
            DropdownMenuItem<String>(value: 'false', child: Text('false')),
          ],
          onChanged: (v) => setState(() {
            _boolean = v == null || v.isEmpty ? null : v == 'true';
            _emit();
          }),
        )),
      FlowFieldShape.enumOf => wrap(DropdownButtonFormField<String>(
          key: ValueKey('f:${spec.path}'),
          initialValue: _enumValue.isEmpty ? null : _enumValue,
          isDense: true,
          items: [
            const DropdownMenuItem<String>(value: '', child: Text('—')),
            for (final option in spec.options)
              DropdownMenuItem<String>(value: option, child: Text(option)),
          ],
          onChanged: (v) => setState(() {
            _enumValue = v ?? '';
            _emit();
          }),
        )),
      FlowFieldShape.cond => wrap(_cond(zh, l10n)),
      FlowFieldShape.listOf => wrap(_listRows(l10n)),
      FlowFieldShape.mapOf => wrap(_pairRows(l10n)),
      FlowFieldShape.outputMap => wrap(_outputRows(l10n)),
      FlowFieldShape.flowRef => wrap(_flowRefRow(context, l10n)),
      FlowFieldShape.modelRef ||
      FlowFieldShape.modeRef =>
        wrap(_choiceRow(context, l10n)),
    };
  }

  /// `call.flow`：优先从同 scope 的流程库里选，仍可手输（比如带 `@revision`）。
  Widget _flowRefRow(BuildContext context, AppLocalizations l10n) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: ValueKey('f:${widget.spec.path}'),
            controller: _scalar,
            decoration: const InputDecoration(isDense: true),
            onChanged: (_) => setState(_emit),
          ),
        ),
        if (widget.flowRefChoices.isNotEmpty)
          IconButton(
            key: ValueKey('pick:${widget.spec.path}'),
            tooltip: l10n.flow_fieldPickFlow,
            icon: const Icon(Icons.account_tree_outlined, size: 18),
            onPressed: () => unawaited(_pickFlowRef(context, l10n)),
          ),
      ],
    );
  }

  Future<void> _pickFlowRef(BuildContext context, AppLocalizations l10n) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l10n.flow_fieldPickFlow,
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final ref in widget.flowRefChoices)
              ListTile(
                key: ValueKey('flow-ref-$ref'),
                title: Text(ref),
                onTap: () => Navigator.pop(sheet, ref),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _scalar.text = picked;
      _emit();
    });
  }

  /// `task.model` / `task.mode`：优先从选中 agent 的可用列表里选，仍可手输模板
  /// 变量。第一项「跟随 agent 默认」写 null，把字段清掉。
  Widget _choiceRow(BuildContext context, AppLocalizations l10n) {
    final choices = widget.choices ?? FlowModelChoices.empty;
    final scheme = Theme.of(context).colorScheme;
    final bodySmall = Theme.of(context).textTheme.bodySmall;
    final currentVal = _manualChoice ? _scalar.text : _choiceValue;
    final known = {for (final o in choices.options) o.value};
    final unavailable = currentVal.isNotEmpty &&
        currentVal != _kFollowDefault &&
        !currentVal.trimLeft().startsWith('{{') &&
        !known.contains(currentVal);

    if (_manualChoice && !choices.switchable) {
      // A8-8：YAML 里的 `{{ inputs.model }}` 不能绕过 switchable=false 锁。
      // 只读展示当前值 + 诊断，不给 TextField，也不给「手动输入 / 选列表」入口。
      final locked = widget.current is String ? widget.current as String : '';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SelectableText(
              locked,
              style: bodySmall,
            ),
          ),
          Text(
            l10n.flow_modelNotSwitchable,
            style: bodySmall?.copyWith(color: scheme.error),
          ),
        ],
      );
    }

    if (_manualChoice) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: ValueKey('f:${widget.spec.path}'),
            controller: _scalar,
            decoration: const InputDecoration(
                isDense: true, border: OutlineInputBorder()),
            onChanged: (_) => setState(_emit),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: ValueKey('choice-pick:${widget.spec.path}'),
              onPressed: () => setState(() {
                _manualChoice = false;
                _choiceValue = _kFollowDefault;
                _emit();
              }),
              child: Text(l10n.flow_modelPick),
            ),
          ),
        ],
      );
    }

    final items = <DropdownMenuItem<String>>[
      DropdownMenuItem<String>(
        value: _kFollowDefault,
        child: Text(
          l10n.flow_modelFollowDefault(
              choices.current ?? l10n.flow_modelCurrentNone),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      for (final o in choices.options)
        DropdownMenuItem<String>(
          value: o.value,
          child: Text(o.label, overflow: TextOverflow.ellipsis),
        ),
      if (unavailable)
        DropdownMenuItem<String>(
          value: currentVal,
          child: Text(
            '$currentVal${l10n.flow_modelUnavailable}',
            style: TextStyle(color: scheme.error),
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
    final effective = items.any((i) => i.value == _choiceValue)
        ? _choiceValue
        : _kFollowDefault;
    final shownHint = choices.hint ??
        (choices.allowManual &&
                choices.options.isEmpty &&
                !choices.loading &&
                _choiceValue == _kFollowDefault
            ? l10n.flow_modelRuntimeBound
            : null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (choices.loading)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(l10n.flow_modelLoading,
                style: bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        DropdownButtonFormField<String>(
          key: ValueKey('f:${widget.spec.path}'),
          initialValue: effective,
          isDense: true,
          isExpanded: true,
          items: items,
          // switchable == false：禁用，只展示当前值。
          onChanged: choices.switchable
              ? (v) => setState(() {
                    _choiceValue = v ?? _kFollowDefault;
                    _emit();
                  })
              : null,
        ),
        if (!choices.switchable)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(l10n.flow_modelNotSwitchable,
                style: bodySmall?.copyWith(color: scheme.error)),
          )
        else if (shownHint != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(shownHint,
                style: bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        // 手动输入只在「允许手输」且「模型可切换」时才给：agent 明确不可切换
        // （switchable=false）时，手输等于绕过它的模型配置；允许手输标记
        // （allowManual）没打开时也不该露出这个入口。
        if (choices.allowManual && choices.switchable)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: ValueKey('choice-manual:${widget.spec.path}'),
              onPressed: () => setState(() {
                _manualChoice = true;
                _scalar.text =
                    _choiceValue == _kFollowDefault ? '' : _choiceValue;
              }),
              child: Text(l10n.flow_modelManual),
            ),
          ),
      ],
    );
  }

  bool _isEmptyValue() {
    switch (widget.spec.shape) {
      case FlowFieldShape.string:
      case FlowFieldShape.text:
        return _scalar.text.trim().isEmpty;
      case FlowFieldShape.int:
        return _numberOrNull(_scalar.text.trim()) == null;
      case FlowFieldShape.intOrInput:
        return _intOrInputOrNull(_scalar.text.trim()) == null;
      case FlowFieldShape.boolean:
        return _boolean == null;
      case FlowFieldShape.enumOf:
        return _enumValue.isEmpty;
      case FlowFieldShape.cond:
        return _condIsJudge
            ? _judge.text.trim().isEmpty
            : _scalar.text.trim().isEmpty;
      case FlowFieldShape.listOf:
        return _list.every((c) => c.text.trim().isEmpty);
      case FlowFieldShape.mapOf:
        return _pairs.every((p) => p.key.text.trim().isEmpty);
      case FlowFieldShape.outputMap:
        return _outputs.every((r) => r.key.text.trim().isEmpty);
      case FlowFieldShape.flowRef:
        return _scalar.text.trim().isEmpty;
      case FlowFieldShape.modelRef:
      case FlowFieldShape.modeRef:
        return false; // 非必填：清成「跟随默认」也合法
    }
  }

  Future<void> _pickRef(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final candidate in widget.refCandidates)
              ListTile(
                key: ValueKey('ref-item-$candidate'),
                title: Text(candidate),
                onTap: () => Navigator.pop(sheet, candidate),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _insertRef(picked));
  }

  Widget _cond(bool zh, AppLocalizations l10n) {
    return Column(
      children: [
        Row(
          children: [
            ChoiceChip(
              label: Text(l10n.flow_fieldCondExpr),
              selected: !_condIsJudge,
              onSelected: (_) => setState(() {
                _condIsJudge = false;
                _emit();
              }),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: Text(l10n.flow_fieldCondJudge),
              selected: _condIsJudge,
              onSelected: (_) => setState(() {
                _condIsJudge = true;
                _emit();
              }),
            ),
          ],
        ),
        if (_condIsJudge) ...[
          TextField(
            key: ValueKey('f:${widget.spec.path}'),
            controller: _judge,
            decoration: InputDecoration(
                labelText: l10n.flow_fieldCondWho, isDense: true),
            onChanged: (_) => setState(_emit),
          ),
          TextField(
            controller: _ask,
            decoration: InputDecoration(
                labelText: l10n.flow_fieldCondAsk, isDense: true),
            onChanged: (_) => setState(_emit),
          ),
        ] else
          TextField(
            key: ValueKey('f:${widget.spec.path}'),
            controller: _scalar,
            decoration: InputDecoration(
              isDense: true,
              suffixIcon: widget.refCandidates.isEmpty
                  ? null
                  : IconButton(
                      tooltip: l10n.flow_refInsert,
                      icon: const Icon(Icons.data_object, size: 18),
                      onPressed: () => unawaited(_pickRef(context)),
                    ),
            ),
            onChanged: (_) => setState(_emit),
          ),
      ],
    );
  }

  Widget _listRows(AppLocalizations l10n) => Column(
        children: [
          for (var i = 0; i < _list.length; i++)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('f:${widget.spec.path}-$i'),
                    controller: _list[i],
                    decoration:
                        InputDecoration(labelText: '#${i + 1}', isDense: true),
                    onChanged: (_) => setState(_emit),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => setState(() {
                    _list.removeAt(i).dispose();
                    _emit();
                  }),
                ),
              ],
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ValueKey('add:${widget.spec.path}'),
              onPressed: () => setState(() {
                _list.add(TextEditingController());
                _emit();
              }),
              icon: const Icon(Icons.add, size: 16),
              label: Text(l10n.flow_fieldAddRow),
            ),
          ),
        ],
      );

  Widget _pairRows(AppLocalizations l10n) => Column(
        children: [
          for (var i = 0; i < _pairs.length; i++)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('f:${widget.spec.path}-k$i'),
                    controller: _pairs[i].key,
                    decoration: InputDecoration(
                        labelText: l10n.flow_fieldKey, isDense: true),
                    onChanged: (_) => setState(_emit),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: ValueKey('f:${widget.spec.path}-v$i'),
                    controller: _pairs[i].value,
                    decoration: InputDecoration(
                        labelText: l10n.flow_fieldValue, isDense: true),
                    onChanged: (_) => setState(_emit),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => setState(() {
                    _pairs.removeAt(i).dispose();
                    _emit();
                  }),
                ),
              ],
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ValueKey('add:${widget.spec.path}'),
              onPressed: () => setState(() {
                _pairs.add(_Pair('', ''));
                _emit();
              }),
              icon: const Icon(Icons.add, size: 16),
              label: Text(l10n.flow_fieldAddRow),
            ),
          ),
        ],
      );

  Widget _outputRows(AppLocalizations l10n) => Column(
        children: [
          for (var i = 0; i < _outputs.length; i++)
            _OutputRowTile(
              key: ObjectKey(_outputs[i]),
              path: widget.spec.path,
              row: _outputs[i],
              index: i,
              l10n: l10n,
              onChanged: () => setState(_emit),
              onRemove: () => setState(() {
                _outputs.removeAt(i).dispose();
                _emit();
              }),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ValueKey('add:${widget.spec.path}'),
              onPressed: () => setState(() {
                _outputs.add(_OutputRow(''));
                _emit();
              }),
              icon: const Icon(Icons.add, size: 16),
              label: Text(l10n.flow_fieldAddRow),
            ),
          ),
        ],
      );
}

class _Pair {
  _Pair(String key, String value)
      : key = TextEditingController(text: key),
        value = TextEditingController(text: value);

  final TextEditingController key;
  final TextEditingController value;

  void dispose() {
    key.dispose();
    value.dispose();
  }
}

class _OutputRow {
  _OutputRow(String key, {this.isEnum = false, this.type = 'string'})
      : key = TextEditingController(text: key),
        values = TextEditingController(),
        original = null;

  /// 从 YAML 读进来的原始值。没动过就原样写回 —— 否则任意一行的编辑都会把
  /// 整张 output 表重编码，丢掉额外键、把含逗号的枚举项拆开、把结构化值压成
  /// `'string'`。
  _OutputRow.from(String key, Object? value)
      : key = TextEditingController(text: key),
        original = value,
        isEnum = value is Map && value.containsKey('enum'),
        values = TextEditingController(
          text: value is Map
              ? (value['enum'] as List? ?? const []).join(', ')
              : '',
        ),
        type = value is String ? value : 'string';

  final TextEditingController key;
  final TextEditingController values;
  final Object? original;
  bool isEnum;
  String type;
  bool dirty = false;

  Object encode() {
    if (!dirty && original != null) return original!;
    if (!isEnum) return type;
    return {
      'enum': [
        for (final v in values.text.split(','))
          if (v.trim().isNotEmpty) v.trim(),
      ],
    };
  }

  void dispose() {
    key.dispose();
    values.dispose();
  }
}

class _OutputRowTile extends StatefulWidget {
  const _OutputRowTile({
    super.key,
    required this.path,
    required this.row,
    required this.index,
    required this.l10n,
    required this.onChanged,
    required this.onRemove,
  });

  final String path;
  final _OutputRow row;
  final int index;
  final AppLocalizations l10n;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  State<_OutputRowTile> createState() => _OutputRowTileState();
}

class _OutputRowTileState extends State<_OutputRowTile> {
  /// 任何编辑都要标脏，否则 `encode()` 会一直返回原始值。
  void _edited([VoidCallback? change]) {
    setState(() {
      widget.row.dirty = true;
      change?.call();
      widget.onChanged();
    });
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final l10n = widget.l10n;
    final knownTypes = ['string', 'int', 'bool', 'number', 'object'];
    // YAML 里可能有这五种之外的类型串：不补进 items 会让 SDK 的
    // DropdownButtonFormField 断言崩溃。
    final types = {...knownTypes, if (row.type.isNotEmpty) row.type}.toList();
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: ValueKey('f:${widget.path}-k${widget.index}'),
            controller: row.key,
            decoration:
                InputDecoration(labelText: l10n.flow_fieldKey, isDense: true),
            onChanged: (_) => _edited(),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 96,
          child: DropdownButtonFormField<String>(
            initialValue: row.isEnum ? 'enum' : 'type',
            isDense: true,
            items: [
              DropdownMenuItem<String>(
                  value: 'type', child: Text(l10n.flow_fieldType)),
              DropdownMenuItem<String>(
                  value: 'enum', child: Text(l10n.flow_fieldEnum)),
            ],
            onChanged: (v) => _edited(() {
              row.isEnum = v == 'enum';
            }),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: row.isEnum
              ? TextField(
                  key: ValueKey('f:${widget.path}-enum${widget.index}'),
                  controller: row.values,
                  decoration: InputDecoration(
                      labelText: l10n.flow_fieldEnumValues, isDense: true),
                  onChanged: (_) => _edited(),
                )
              : DropdownButtonFormField<String>(
                  initialValue: row.type,
                  isDense: true,
                  items: [
                    for (final t in types)
                      DropdownMenuItem<String>(value: t, child: Text(t)),
                  ],
                  onChanged: (v) => _edited(() {
                    row.type = v ?? 'string';
                  }),
                ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 16),
          onPressed: widget.onRemove,
        ),
      ],
    );
  }
}
