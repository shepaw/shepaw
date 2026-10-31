import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/flow_models.dart';
import '../peer/services/hub_flow.dart';
import 'flow_design_screen.dart';
import 'flow_run_screen.dart';

/// 主机上的流程库：点一项进设计视图，右侧"运行"开一次运行并跳到运行视图。
class FlowLibraryScreen extends StatefulWidget {
  const FlowLibraryScreen({
    super.key,
    required this.peerId,
    this.scope = '',
    this.client,
  });

  final String peerId;

  /// `lib`（缺省）或 `group:<gid>`。
  final String scope;
  final HubFlow? client;

  @override
  State<FlowLibraryScreen> createState() => _FlowLibraryScreenState();
}

class _FlowLibraryScreenState extends State<FlowLibraryScreen> {
  late final HubFlow _client = widget.client ?? HubFlow();
  List<FlowSummary>? _flows;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final flows = await _client.list(widget.peerId, scope: widget.scope);
    if (!mounted) return;
    setState(() {
      _flows = flows;
      _loading = false;
    });
  }

  Future<void> _start(FlowSummary flow) async {
    final l10n = AppLocalizations.of(context);
    final result = await _client.start(
      widget.peerId,
      scope: widget.scope,
      name: flow.name,
    );
    if (!mounted) return;
    final runId = result.runId;
    if (!result.ok || runId == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.reachable
            ? (result.error ?? l10n.flow_startFailed)
            : l10n.flow_hostNoReply),
      ));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          FlowRunScreen(peerId: widget.peerId, runId: runId, title: flow.name),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final flows = _flows;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.flow_libraryTitle),
        actions: [
          IconButton(
            tooltip: l10n.flow_refresh,
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : flows == null
              ? Center(child: Text(l10n.flow_hostNoReply))
              : flows.isEmpty
                  ? Center(child: Text(l10n.flow_libraryEmpty))
                  : ListView(
                      children: [
                        for (final flow in flows)
                          ListTile(
                            leading: const Icon(Icons.account_tree_outlined),
                            title: Text(flow.name),
                            subtitle:
                                Text(l10n.flow_revisionLabel(flow.latest)),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => FlowDesignScreen(
                                  peerId: widget.peerId,
                                  name: flow.name,
                                  scope: widget.scope,
                                  client: _client,
                                ),
                              ),
                            ),
                            trailing: TextButton(
                              onPressed: () => _start(flow),
                              child: Text(l10n.flow_startRun),
                            ),
                          ),
                      ],
                    ),
    );
  }
}
