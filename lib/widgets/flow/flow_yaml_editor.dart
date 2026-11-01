import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/services/hub_flow.dart';

/// 一段可以直接改的流程定义（C.6 / F19）。
///
/// 校验和改写都在主机上做：这里改完立刻发 `flow_validate_req`，用回来的诊断
/// 标出写不通的地方。App 自己不做任何校验。
///
/// `onApply` 为 null 时是只读（手机上看源码）。
class FlowYamlEditor extends StatefulWidget {
  const FlowYamlEditor({
    super.key,
    required this.yaml,
    this.validate,
    this.readOnly = false,
    this.applyLabel,
    this.hint,
    this.onApply,
    this.onChanged,
  });

  final String yaml;

  /// 把当前这段交给主机校验；为 null 表示这段没法单独校验（比如改写时只改
  /// 一个容器的子步骤），直接交给主机，由它来判断。
  final Future<FlowValidation?> Function(String text)? validate;

  /// 输入框里的提示。
  final String? hint;

  final bool readOnly;
  final String? applyLabel;

  /// 点了"应用"。参数是最新的 YAML，以及刚才那次校验的结果（可能为 null：
  /// 这段没法单独校验时）。
  ///
  /// 校验结果要一起带出去：调用方必须同时更新节点树和诊断，只换 YAML 会让
  /// 界面上的树停在改之前的状态。
  final void Function(String yaml, FlowValidation? checked)? onApply;
  final void Function(String yaml)? onChanged;

  @override
  State<FlowYamlEditor> createState() => _FlowYamlEditorState();
}

class _FlowYamlEditorState extends State<FlowYamlEditor> {
  late final TextEditingController _field =
      TextEditingController(text: widget.yaml);
  FlowValidation? _checked;
  bool _checking = false;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _field.addListener(_notifyChanged);
  }

  @override
  void dispose() {
    _field.removeListener(_notifyChanged);
    _field.dispose();
    super.dispose();
  }

  void _notifyChanged() => widget.onChanged?.call(_field.text);

  Future<void> _check() async {
    final validate = widget.validate;
    if (validate == null) return;
    setState(() => _checking = true);
    final checked = await validate(_field.text);
    if (!mounted) return;
    setState(() {
      _checked = checked;
      _checking = false;
    });
  }

  Future<void> _apply() async {
    final validate = widget.validate;
    setState(() => _applying = true);
    FlowValidation? checked;
    if (validate != null) {
      checked = await validate(_field.text);
    }
    if (!mounted) return;
    setState(() => _applying = false);
    final l10n = AppLocalizations.of(context);
    if (validate != null) {
      if (checked == null) {
        _snack(l10n.flow_hostNoReply);
        return;
      }
      final errors = checked.diagnostics.where((d) => d.isError).length;
      if (errors > 0) {
        _snack(l10n.flow_hasProblems(errors));
        return;
      }
    }
    widget.onApply?.call(_field.text, checked);
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final checked = _checked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('yaml-editor'),
            controller: _field,
            readOnly: widget.readOnly,
            expands: true,
            maxLines: null,
            minLines: null,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText:
                  widget.hint ?? 'steps:\n  - id: a\n    task: {prompt: "做"}',
              isDense: true,
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (checked != null)
          for (final d in checked.diagnostics)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                d.at.isEmpty ? d.message : '[${d.at}] ${d.message}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: d.isError ? theme.colorScheme.error : Colors.orange,
                ),
              ),
            ),
        Row(
          children: [
            if (widget.validate != null)
              OutlinedButton(
                key: const ValueKey('yaml-validate'),
                onPressed: _checking ? null : _check,
                child: Text(l10n.flow_validate),
              ),
            if (widget.validate != null) const SizedBox(width: 8),
            if (widget.onApply != null && !widget.readOnly)
              FilledButton(
                key: const ValueKey('yaml-apply'),
                onPressed: _checking || _applying ? null : _apply,
                child: _applying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(widget.applyLabel ?? l10n.flow_inspectorApply),
              ),
          ],
        ),
      ],
    );
  }
}
