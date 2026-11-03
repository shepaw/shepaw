import 'package:flutter/material.dart';

import '../../controllers/flow/flow_names.dart';
import '../../controllers/flow/flow_templates.dart';
import '../../l10n/app_localizations.dart';

/// 新建的起点：空白 / 内置模板 / 复制现有流程。
enum FlowNewSource { blank, template, copy }

/// 用户填完的结果。
class FlowNewRequest {
  const FlowNewRequest({
    required this.name,
    required this.source,
    this.sourceName,
  });

  final String name;
  final FlowNewSource source;

  /// 模板 id 或要复制的流程名。[FlowNewSource.blank] 时为 null。
  final String? sourceName;
}

/// 新建流程：空白 / 从模板 / 复制现有。
///
/// 名字的问题在这里就拦掉，省一次往返；但真正的保证在主机 —— 保存带
/// `create_only`，撞名会被拒，而不是静默存成同名流程的下一版。
Future<FlowNewRequest?> showNewFlowDialog(
  BuildContext context, {
  required Iterable<String> existing,
  List<FlowTemplateEntry> templates = const [],
}) {
  return showDialog<FlowNewRequest>(
    context: context,
    builder: (dialogContext) => _NewFlowDialog(
      existing: existing.map((e) => e.toLowerCase()).toSet(),
      templates: templates,
    ),
  );
}

class _NewFlowDialog extends StatefulWidget {
  const _NewFlowDialog({
    required this.existing,
    required this.templates,
  });

  final Set<String> existing;
  final List<FlowTemplateEntry> templates;

  @override
  State<_NewFlowDialog> createState() => _NewFlowDialogState();
}

class _NewFlowDialogState extends State<_NewFlowDialog> {
  final TextEditingController _name = TextEditingController();
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  FlowNewSource _source = FlowNewSource.blank;
  String? _sourceName;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String? _validate(String? raw, AppLocalizations l10n) {
    final name = (raw ?? '').trim();
    switch (FlowNameRules.check(name)) {
      case null:
        break;
      case FlowNameProblem.empty:
        return l10n.flow_newNameInvalid;
      case FlowNameProblem.reserved:
        return l10n.flow_newNameReserved;
      case FlowNameProblem.invalid:
        return l10n.flow_newNameInvalid;
    }
    if (widget.existing.contains(name.toLowerCase())) {
      return l10n.flow_newNameTaken;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      title: Text(l10n.flow_newTitle),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const ValueKey('new-flow-name'),
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.flow_newName,
                hintText: l10n.flow_newNameHint,
              ),
              validator: (value) => _validate(value, l10n),
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.flow_newSource,
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  key: const ValueKey('source-blank'),
                  label: Text(l10n.flow_newSourceBlank),
                  selected: _source == FlowNewSource.blank,
                  onSelected: (_) =>
                      setState(() => _source = FlowNewSource.blank),
                ),
                if (widget.templates.isNotEmpty)
                  ChoiceChip(
                    key: const ValueKey('source-template'),
                    label: Text(l10n.flow_newSourceTemplate),
                    selected: _source == FlowNewSource.template,
                    onSelected: (_) => setState(() {
                      _source = FlowNewSource.template;
                      _sourceName ??= widget.templates.first.id;
                    }),
                  ),
                ChoiceChip(
                  key: const ValueKey('source-copy'),
                  label: Text(l10n.flow_newSourceCopy),
                  selected: _source == FlowNewSource.copy,
                  onSelected: (_) => setState(() {
                    _source = FlowNewSource.copy;
                    _sourceName = null;
                  }),
                ),
              ],
            ),
            if (_source == FlowNewSource.template) ...[
              const SizedBox(height: 8),
              _TemplatePicker(
                templates: widget.templates,
                current: _sourceName,
                onChanged: (id) => setState(() => _sourceName = id),
              ),
            ],
            if (_source == FlowNewSource.copy) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: const ValueKey('copy-source'),
                initialValue: _sourceName,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.flow_newSourceCopy,
                  isDense: true,
                ),
                items: [
                  for (final name in widget.existing)
                    DropdownMenuItem<String>(value: name, child: Text(name)),
                ],
                onChanged: (v) => setState(() => _sourceName = v),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          key: const ValueKey('new-flow-create'),
          onPressed: _submit,
          child: Text(l10n.flow_new),
        ),
      ],
    );
  }

  void _submit() {
    if (_form.currentState?.validate() != true) return;
    // 选了模板 / 复制却没选具体哪一份，别让用户带着空值过去。
    if (_source != FlowNewSource.blank &&
        (_sourceName == null || _sourceName!.isEmpty)) {
      return;
    }
    Navigator.pop(
      context,
      FlowNewRequest(
        name: _name.text.trim(),
        source: _source,
        sourceName: _source == FlowNewSource.blank ? null : _sourceName,
      ),
    );
  }
}

/// 模板选择。文案用客户端的（模板 id 是唯一标识）。
class _TemplatePicker extends StatelessWidget {
  const _TemplatePicker({
    required this.templates,
    required this.current,
    required this.onChanged,
  });

  final List<FlowTemplateEntry> templates;
  final String? current;
  final void Function(String id) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return Column(
      children: [
        for (final entry in templates)
          RadioListTile<String>(
            key: ValueKey('tpl-${entry.id}'),
            value: entry.id,
            groupValue: current,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(zh ? entry.titleZh : entry.titleEn),
            subtitle: Text(
              zh ? entry.blurbZh : entry.blurbEn,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
      ],
    );
  }
}
