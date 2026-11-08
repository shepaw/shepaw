import 'package:flutter/material.dart';

import '../../controllers/flow/flow_executor.dart';
import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_models.dart';
import '../../peer/services/hub_flow.dart';
import 'flow_runs_pane.dart';

/// 流程详情的默认页：先看清楚「这是个什么流程、跑得怎么样」，再决定编辑还是运行。
///
/// 以前点进流程直接是整页编辑器，看流程的人也被迫进编辑态；现在编辑只在
/// 桌面端的独立 Tab 里，这一页在手机上也可用（只读）。
class FlowOverviewPane extends StatelessWidget {
  const FlowOverviewPane({
    super.key,
    required this.flow,
    required this.client,
    required this.peerId,
    required this.scope,
    required this.onStart,
    required this.onOpenRun,
    this.onRehearse,
    this.draftBanner,
  });

  final FlowSummary flow;
  final HubFlow client;
  final String peerId;
  final String scope;

  /// 桌面才有「演练」入口；手机只读，不给灰掉的按钮。
  final VoidCallback? onRehearse;

  final VoidCallback onStart;
  final void Function(String runId, String title) onOpenRun;

  /// 上次没保存的草稿：横幅放在概览顶部，不再进页面时弹窗拦着。
  final Widget? draftBanner;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final description = flow.description?.trim() ?? '';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (draftBanner != null) ...[
            draftBanner!,
            const SizedBox(height: 12),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(flow.name, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text(
                    description.isNotEmpty
                        ? description
                        : l10n.flow_overviewNoDescription,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: description.isNotEmpty
                          ? null
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Chip(
                        label: Text(l10n.flow_revisionLabel(flow.latest)),
                        visualDensity: VisualDensity.compact,
                      ),
                      if (flow.updatedMs != null && flow.updatedMs! > 0)
                        Text(
                          l10n.flow_overviewUpdated(
                              _when(flow.updatedMs!, l10n)),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _RuntimeParams(
            client: client,
            peerId: peerId,
            name: flow.name,
            scope: scope,
          ),
          const SizedBox(height: 16),
          // 「开始运行」是这一页唯一的主按钮；演练用不同图标 + 明确写出
          // 「不会真调用 agent」，别再和运行混成一个播放图标。
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const ValueKey('overview-start'),
                onPressed: onStart,
                icon: const Icon(Icons.play_arrow),
                label: Text(l10n.flow_overviewStart),
              ),
              if (onRehearse != null)
                OutlinedButton.icon(
                  key: const ValueKey('overview-rehearse'),
                  onPressed: onRehearse,
                  icon: const Icon(Icons.science_outlined),
                  label: Text(l10n.flow_overviewRehearse),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Text(l10n.flow_overviewRecentRuns,
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          SizedBox(
            height: 200,
            child: FlowRunsPane(
              client: client,
              peerId: peerId,
              scope: scope,
              name: flow.name,
              limit: 3,
              showHeader: false,
              onOpenRun: onOpenRun,
            ),
          ),
        ],
      ),
    );
  }

  String _when(int ms, AppLocalizations l10n) {
    final diff = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inMinutes < 1) return l10n.flow_runsJustNow;
    if (diff.inHours < 1) return l10n.flow_runsMinutesAgo(diff.inMinutes);
    if (diff.inDays < 1) return l10n.flow_runsHoursAgo(diff.inHours);
    return l10n.flow_runsDaysAgo(diff.inDays);
  }
}

class _RuntimeParams extends StatefulWidget {
  const _RuntimeParams({
    required this.client,
    required this.peerId,
    required this.name,
    required this.scope,
  });

  final HubFlow client;
  final String peerId;
  final String name;
  final String scope;

  @override
  State<_RuntimeParams> createState() => _RuntimeParamsState();
}

class _RuntimeParamsState extends State<_RuntimeParams> {
  List<FlowInputSpec> _inputs = const [];
  Map<String, String> _outputs = const {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final got = await widget.client.get(
      widget.peerId,
      widget.name,
      scope: widget.scope,
    );
    if (!mounted) return;
    final yaml = got?.yaml ?? '';
    setState(() {
      _loaded = true;
      _inputs = peekInputs(yaml);
      _outputs = FlowHeaderPeek.outputs(yaml);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('runtime-params'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.flow_runtimeInputs, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        if (_inputs.isEmpty)
          Text(l10n.flow_noRuntimeInputs,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ))
        else
          for (final input in _inputs)
            Text(
              '${input.name} · ${input.type}'
              '${input.required ? ' · ${l10n.flow_inputRequiredShort}' : ''}',
            ),
        if (_outputs.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(l10n.flow_runtimeOutputs, style: theme.textTheme.titleSmall),
          for (final name in _outputs.keys) Text(name),
        ],
      ],
    );
  }
}
