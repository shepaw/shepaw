import 'package:flutter/material.dart';

import '../../controllers/flow/flow_names.dart';
import '../../l10n/app_localizations.dart';

/// 新建流程：现在只有「空白」一种起步方式（模板是 M6 补全的事）。
///
/// 名字的问题在这里就拦掉，省一次往返；但真正的保证在主机 —— 保存带
/// `create_only`，撞名会被拒（主机的 `save` 本身不做冲突检测）。
Future<String?> showNewFlowDialog(
  BuildContext context, {
  required Iterable<String> existing,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) =>
        _NewFlowDialog(existing: existing.map((e) => e.toLowerCase()).toSet()),
  );
}

class _NewFlowDialog extends StatefulWidget {
  const _NewFlowDialog({required this.existing});

  final Set<String> existing;

  @override
  State<_NewFlowDialog> createState() => _NewFlowDialogState();
}

class _NewFlowDialogState extends State<_NewFlowDialog> {
  final TextEditingController _name = TextEditingController();
  final GlobalKey<FormState> _form = GlobalKey<FormState>();

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
    final scheme = Theme.of(context).colorScheme;
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
            Row(
              children: [
                Icon(Icons.account_tree_outlined,
                    size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.flow_newBlankHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
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
    Navigator.pop(context, _name.text.trim());
  }
}
