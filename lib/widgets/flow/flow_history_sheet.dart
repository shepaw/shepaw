import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/services/hub_flow.dart';
import '../../utils/layout_utils.dart';

/// 版本历史（方案「关键设计 12」）。
///
/// `flow_get` 已经支持 `revision`，`flow_diff_req` 支持 `from_revision` /
/// `to_revision`，所以只做 App 侧：列出 1..latest，看某版和当前的差异，或者
/// 「以此版为草稿」（载入成未保存草稿，保存即成为新一版）。
Future<FlowHistoryChoice?> showFlowHistorySheet(
  BuildContext context, {
  required HubFlow client,
  required String peerId,
  required String scope,
  required String name,
  required int latest,
}) {
  final sheet = FlowHistorySheet(
    client: client,
    peerId: peerId,
    scope: scope,
    name: name,
    latest: latest,
  );
  if (LayoutUtils.isDesktopLayout(context)) {
    return showDialog<FlowHistoryChoice>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: SizedBox(width: 480, height: 560, child: sheet),
      ),
    );
  }
  return showModalBottomSheet<FlowHistoryChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheetContext) => SizedBox(
      height: MediaQuery.sizeOf(sheetContext).height * 0.8,
      child: sheet,
    ),
  );
}

class FlowHistoryChoice {
  const FlowHistoryChoice({required this.revision, required this.yaml});

  final int revision;
  final String yaml;
}

class FlowHistorySheet extends StatefulWidget {
  const FlowHistorySheet({
    super.key,
    required this.client,
    required this.peerId,
    required this.scope,
    required this.name,
    required this.latest,
    this.onChosen,
    this.onClose,
  });

  /// 嵌在工作流右侧时用回调，不再 pop 对话框。
  final ValueChanged<FlowHistoryChoice>? onChosen;
  final VoidCallback? onClose;

  final HubFlow client;
  final String peerId;
  final String scope;
  final String name;
  final int latest;

  @override
  State<FlowHistorySheet> createState() => _FlowHistorySheetState();
}

class _FlowHistorySheetState extends State<FlowHistorySheet> {
  int? _selected;
  String? _diffSummary;
  bool _busy = false;

  Future<void> _pick(int revision) async {
    setState(() {
      _selected = revision;
      _diffSummary = null;
      _busy = true;
    });
    final got = await widget.client.diff(
      widget.peerId,
      scope: widget.scope,
      name: widget.name,
      fromRevision: revision,
      toRevision: widget.latest,
    );
    if (!mounted) return;
    final diff = got.diff;
    setState(() {
      _busy = false;
      _diffSummary = diff == null
          ? got.error
          : (diff.isEmpty
              ? AppLocalizations.of(context).flow_historyNoDiff
              : AppLocalizations.of(context)
                  .flow_diffSummary(diff.nodes.length + diff.header.length));
    });
  }

  Future<void> _useAsDraft() async {
    final revision = _selected;
    if (revision == null) return;
    final got = await widget.client.get(
      widget.peerId,
      widget.name,
      scope: widget.scope,
      revision: revision,
    );
    if (!mounted) return;
    if (got == null) return;
    final choice = FlowHistoryChoice(revision: revision, yaml: got.yaml);
    if (widget.onChosen != null) {
      widget.onChosen!(choice);
      return;
    }
    Navigator.pop(context, choice);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final column = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Row(
                children: [
                  if (widget.onClose != null)
                    IconButton(
                      tooltip: l10n.common_back,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: widget.onClose,
                    ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                          left: widget.onClose == null ? 12 : 0),
                      child: Text(l10n.flow_historyTitle,
                          style: theme.textTheme.titleMedium),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (var revision = widget.latest; revision >= 1; revision--)
                    ListTile(
                      key: ValueKey('rev-$revision'),
                      selected: _selected == revision,
                      leading: const Icon(Icons.history),
                      title: Text(l10n.flow_revisionLabel(revision)),
                      subtitle: revision == widget.latest
                          ? Text(l10n.flow_historyCurrent)
                          : null,
                      onTap: () => unawaited(_pick(revision)),
                    ),
                ],
              ),
            ),
            if (_busy)
              const LinearProgressIndicator()
            else if (_diffSummary != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(_diffSummary!,
                    style: theme.textTheme.bodySmall),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                key: const ValueKey('history-use'),
                onPressed: _selected == null ? null : _useAsDraft,
                child: Text(l10n.flow_historyUseAsDraft),
              ),
            ),
          ],
    );
    if (widget.onChosen != null) return column;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: column,
      ),
    );
  }
}
