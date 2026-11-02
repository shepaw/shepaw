import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/flow/flow_diagnostics.dart';
import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_models.dart';
import '../../peer/services/hub_flow.dart';

/// 诊断面板（方案 M7）。
///
/// 点一条就跳到出问题的节点。诚实的限制写在这里：诊断只有 `at`（节点路径）和
/// 一句中文，**没有错误码、没有字段指针**，所以我们只能定位到节点，定位不到具
/// 体是哪个输入框写错了 —— 界面上不会假装能标红某个字段。
class FlowDiagnosticsPanel extends StatelessWidget {
  const FlowDiagnosticsPanel({
    super.key,
    required this.diagnostics,
    required this.tree,
    this.onLocate,
  });

  final List<FlowDiagnostic> diagnostics;

  /// 当前节点树。`at` 要按树里的 id 才能定位到节点。
  final List<FlowNode> tree;

  /// 点一条诊断：参数是要定位到的目标。
  final void Function(FlowDiagnosticTarget target)? onLocate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (diagnostics.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          l10n.flow_diagnosticsNone,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text(
              l10n.flow_diagnosticsTitle(diagnostics.length),
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          for (final d in diagnostics)
            ListTile(
              key: ValueKey('diag-${d.at}-${d.message}'),
              dense: true,
              leading: Icon(
                d.isError ? Icons.error_outline : Icons.warning_amber_outlined,
                size: 18,
                color: d.isError ? scheme.error : Colors.orange,
              ),
              title: Text(
                d.message,
                style: theme.textTheme.bodySmall,
              ),
              subtitle: d.at.isEmpty ? null : Text(d.at),
              trailing: IconButton(
                tooltip: l10n.flow_diagnosticsCopy,
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () => _copy(context, d),
              ),
              onTap: onLocate == null
                  ? null
                  : () => onLocate!(resolveDiagnostic(d, tree)),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Future<void> _copy(BuildContext context, FlowDiagnostic d) async {
    // 复制出来方便贴给群主 / 自己排查：消息是中文，英文界面下也是中文。
    final text = d.at.isEmpty ? d.message : '[${d.at}] ${d.message}';
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).flow_diagnosticsCopied),
      ),
    );
  }
}
