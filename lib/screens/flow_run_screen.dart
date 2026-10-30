import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/flow_models.dart';
import '../peer/services/hub_flow.dart';
import '../widgets/flow/flow_node_tree.dart';

/// 工作流运行视图（方案 C.2）：节点树叠状态，随 `flow.*` 事件更新；
/// 关卡直接点选项作答；点节点看完整输出，有会话的可以"查看会话"。
class FlowRunScreen extends StatefulWidget {
  const FlowRunScreen({
    super.key,
    required this.peerId,
    required this.runId,
    this.title,
    this.client,
    this.onOpenSession,
  });

  final String peerId;
  final String runId;
  final String? title;

  /// 测试里换成假的。
  final HubFlow? client;

  /// 点"查看会话"：参数是节点上的引擎会话键。App 在这里跳到只读会话页。
  final void Function(FlowNode node)? onOpenSession;

  @override
  State<FlowRunScreen> createState() => _FlowRunScreenState();
}

class _FlowRunScreenState extends State<FlowRunScreen> {
  late final HubFlow _client = widget.client ?? HubFlow();
  StreamSubscription<FlowEvent>? _sub;
  Timer? _refetch;
  FlowRunView? _run;
  bool _loading = true;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _sub = _client.runEvents(widget.peerId).listen(_onEvent);
    unawaited(_load());
  }

  @override
  void dispose() {
    _refetch?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final run = await _client.run(widget.peerId, widget.runId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (run != null) {
        _run = run;
        _loadFailed = false;
      } else if (_run == null) {
        _loadFailed = true;
      }
    });
  }

  void _onEvent(FlowEvent event) {
    if (event.runId != widget.runId || !mounted) return;
    final run = _run;
    if (run != null) {
      setState(() {
        if (event.node != null) {
          _run =
              run.withNodeStatus(event.node!, event.nodeStatus!, event.attempt);
        } else if (event.runStatus != null) {
          _run = run.withRunStatus(event.runStatus!);
        }
      });
    }
    // 事件只带状态，输出和轮次要重新读；合并短时间内的多条。
    _refetch?.cancel();
    _refetch = Timer(const Duration(milliseconds: 400), _load);
  }

  Future<void> _answer(FlowNode node, String choice) async {
    final result =
        await _client.answerGate(widget.peerId, widget.runId, node.key, choice);
    if (!mounted) return;
    if (!result.ok) {
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.reachable
              ? (result.error ?? l10n.flow_answerFailed)
              : l10n.flow_hostNoReply)));
    }
    unawaited(_load());
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(l10n.flow_cancelRunTitle),
          content: Text(l10n.flow_cancelRunBody),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.flow_keepWaiting)),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.flow_cancelRun)),
          ],
        );
      },
    );
    if (confirmed != true) return;
    final result = await _client.cancel(widget.peerId, widget.runId);
    if (!mounted) return;
    if (!result.ok) {
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.reachable
              ? (result.error ?? l10n.flow_cancelFailed)
              : l10n.flow_hostNoReply)));
    }
    unawaited(_load());
  }

  void _showNode(FlowNode node) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final l10n = AppLocalizations.of(context);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.55,
          maxChildSize: 0.9,
          builder: (context, controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.all(16),
            children: [
              Text(flowKindTitle(l10n, node),
                  style: Theme.of(context).textTheme.titleMedium),
              if (node.status != null) ...[
                const SizedBox(height: 4),
                Text(l10n.flow_statusLine(flowStatusLabel(l10n, node.status!)) +
                    (node.attempt > 1
                        ? l10n.flow_attemptSuffix(node.attempt)
                        : '')),
              ],
              if (node.error != null) ...[
                const SizedBox(height: 12),
                SelectableText(node.error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              if (node.text != null) ...[
                const SizedBox(height: 12),
                SelectableText(node.text!),
              ],
              if (node.session != null && widget.onOpenSession != null) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  icon: const Icon(Icons.forum_outlined),
                  label: Text(l10n.flow_viewSession),
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onOpenSession!(node);
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final run = _run;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? AppLocalizations.of(context).flow_runTitle),
        actions: [
          if (run != null && !run.status.isFinished)
            IconButton(
              tooltip: AppLocalizations.of(context).flow_cancelRun,
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: _cancel,
            ),
          IconButton(
            tooltip: AppLocalizations.of(context).flow_refresh,
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _body(run),
    );
  }

  Widget _body(FlowRunView? run) {
    if (run == null) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      final l10n = AppLocalizations.of(context);
      return Center(
          child:
              Text(_loadFailed ? l10n.flow_runLoadFailed : l10n.flow_noData));
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _RunHeader(run: run),
        const SizedBox(height: 12),
        FlowNodeTree(
          nodes: run.tree,
          onTapNode: _showNode,
          onAnswerGate: _answer,
        ),
      ],
    );
  }
}

class _RunHeader extends StatelessWidget {
  const _RunHeader({required this.run});

  final FlowRunView run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final (label, color) = switch (run.status) {
      FlowRunStatus.running => (l10n.flow_runRunning, Colors.blue),
      FlowRunStatus.succeeded => (l10n.flow_runSucceeded, Colors.green),
      FlowRunStatus.failed => (l10n.flow_runFailed, Colors.red),
      FlowRunStatus.cancelled => (l10n.flow_runCancelled, Colors.grey),
    };
    return Row(
      children: [
        Icon(Icons.account_tree_outlined, color: color),
        const SizedBox(width: 8),
        Text(label, style: theme.textTheme.titleMedium?.copyWith(color: color)),
        const Spacer(),
        Text(l10n.flow_tasksUsed(run.tasksUsed),
            style: theme.textTheme.bodySmall),
      ],
    );
  }
}
