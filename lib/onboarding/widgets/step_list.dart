import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../host_install_controller.dart';

/// 「准备主机」那页的步骤列表。
///
/// 每一步四种样子：待做、进行中（带已用秒数）、完成（右侧附注）、失败
/// （展开错误和出路）。
class StepList extends StatelessWidget {
  const StepList({
    super.key,
    required this.steps,
    required this.elapsed,
    required this.failedDetailBuilder,
    required this.failureDetail,
    this.logTail,
    this.onRetry,
    this.onOpenLog,
  });

  final List<HostStepView> steps;

  /// 进行中那一步已经跑了多久。
  final Duration elapsed;

  /// 失败步骤的标题。
  final String Function(HostInstallStep step) failedDetailBuilder;

  final String? failureDetail;
  final String? logTail;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenLog;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final view in steps) ...[
          _StepRow(
            view: view,
            elapsedSeconds: view.state == HostStepState.running
                ? elapsed.inSeconds
                : null,
            label: _label(l10n, view.step),
          ),
          if (view.state == HostStepState.failed)
            _FailurePanel(
              title: failedDetailBuilder(view.step),
              detail: failureDetail,
              logTail: logTail,
              onRetry: onRetry,
              onOpenLog: onOpenLog,
            ),
        ],
      ],
    );
  }

  String _label(AppLocalizations l10n, HostInstallStep step) {
    switch (step) {
      case HostInstallStep.install:
        return l10n.hostInstall_stepInstall;
      case HostInstallStep.start:
        return l10n.hostInstall_stepStart;
      case HostInstallStep.connect:
        return l10n.hostInstall_stepConnect;
    }
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.view,
    required this.label,
    this.elapsedSeconds,
  });

  final HostStepView view;
  final String label;
  final int? elapsedSeconds;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (view.state) {
      HostStepState.done => (Icons.check_circle, scheme.primary),
      HostStepState.running => (Icons.timelapse, scheme.primary),
      HostStepState.failed => (Icons.error_outline, scheme.error),
      HostStepState.pending => (Icons.circle_outlined, scheme.outline),
    };
    final note = view.note;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          if (view.state == HostStepState.running && elapsedSeconds != null)
            Text(
              '${elapsedSeconds}s…',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else if (view.state == HostStepState.done &&
              note != null &&
              note.isNotEmpty)
            Text(
              l10n.hostInstall_bundled(note),
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _FailurePanel extends StatelessWidget {
  const _FailurePanel({
    required this.title,
    this.detail,
    this.logTail,
    this.onRetry,
    this.onOpenLog,
  });

  final String title;
  final String? detail;
  final String? logTail;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenLog;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 32, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (onRetry != null)
                FilledButton(
                  onPressed: onRetry,
                  child: Text(l10n.gate_retry),
                ),
              if (onOpenLog != null && (logTail?.isNotEmpty ?? false))
                OutlinedButton(
                  onPressed: onOpenLog,
                  child: Text(l10n.hostInstall_openLog),
                ),
            ],
          ),
          if (logTail != null && logTail!.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                l10n.gate_details,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              children: [
                SizedBox(
                  width: double.infinity,
                  child: SelectableText(
                    logTail!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            )
          else if (detail != null && detail!.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                l10n.gate_details,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              children: [
                SizedBox(
                  width: double.infinity,
                  child: SelectableText(
                    detail!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
