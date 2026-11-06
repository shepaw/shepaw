import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/flow_models.dart';
import '../peer/peer_approval_payload.dart';
import '../peer/services/flow_session_open.dart';
import '../peer/services/hub_flow.dart';
import '../services/approval/pending_approval_hub.dart';
import '../widgets/flow/flow_node_tree.dart';
import '../widgets/flow/flow_yaml.dart';
import '../widgets/flow/flow_yaml_editor.dart';

/// P6：「去回答」要定位到那张待答卡片。孤儿卡落的确定性消息行是
/// `peer_form_<approval_id>`；提醒项 id 是 `action:<form_id>`（form_id 就等于
/// approval_id）。找不到待答项时返回 null —— 只打开会话，不强求高亮。
@visibleForTesting
String? pendingFlowFormMessageId(String channelId) {
  for (final item in PendingApprovalHub.instance.itemsForChannel(channelId)) {
    final mid = item.messageId;
    if (mid != null && mid.isNotEmpty) return mid;
    const prefix = 'action:';
    if (item.id.startsWith(prefix)) {
      final formId = item.id.substring(prefix.length);
      if (formId.isNotEmpty) {
        return PeerApprovalPayload.formCardMessageId(formId);
      }
    }
  }
  return null;
}

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
    this.onDeleted,
  });

  final String peerId;
  final String runId;
  final String? title;

  /// 测试里换成假的。
  final HubFlow? client;

  /// 点"查看会话"的可选覆盖。不传时屏幕自己按 `psess_<sessionId>` 打开
  /// 普通私聊（[openFlowNodeSession]），调用方不必再接线。
  final void Function(FlowNode node)? onOpenSession;

  /// 这次运行被删掉了：调用方退回上一层（列表里也不该再有它）。
  final VoidCallback? onDeleted;

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
          _run = run.withNodeStatus(
            event.node!,
            event.nodeStatus!,
            event.attempt,
            sessionId: event.sessionId,
          );
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

  /// 删掉这次运行（B.6 / C.8）：只有走完了才能删，主机那边还会把节点会话
  /// 从折叠组里收起来。
  Future<void> _deleteRun() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(l10n.flow_deleteRunTitle),
          content: Text(l10n.flow_deleteRunBody),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.flow_keepWaiting)),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.flow_deleteRun)),
          ],
        );
      },
    );
    if (confirmed != true) return;
    final result = await _client.deleteRun(widget.peerId, widget.runId);
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.reachable
              ? (result.error ?? l10n.flow_deleteRunFailed)
              : l10n.flow_hostNoReply)));
      return;
    }
    widget.onDeleted?.call();
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
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

  /// 默认的「查看会话」：节点会话就是一条普通私聊，频道 id 由主机下发的
  /// 真会话 id 拼出来。调用方传了 [FlowRunScreen.onOpenSession] 就走覆盖。
  /// P6：节点在等用户回答时顺带把待答卡片的高亮 id 带上，点进去直接定位。
  void _openSession(FlowNode node) {
    final override = widget.onOpenSession;
    if (override != null) {
      override(node);
      return;
    }
    // 只有主机发下来的真节点会话（`flow_...`）能拼 `psess_` 频道。旧运行 /
    // 群运行的条目可能还留着 `flow:<rid>:<node>` / `group:<gid>:<sid>:...`
    // 这类引擎槽位 key；硬拼会建出一个永远没有消息的假会话。格式不合法时
    // 留在运行页。
    final guardedSessionId = flowFoldedSessionId(node.sessionId ?? '');
    if (guardedSessionId == null) return;
    final l10n = AppLocalizations.of(context);
    unawaited(openFlowSession(
      peerId: widget.peerId,
      sessionId: guardedSessionId,
      remoteAgentId: node.agentId ?? '',
      title: l10n.flow_sessionBanner(node.id),
      highlightMessageId: node.status?.isWaitingForUser == true
          ? pendingFlowFormMessageId(flowSessionChannelId(guardedSessionId))
          : null,
    ));
  }

  /// P6：顶部「运行会话」入口打开本次运行的惜宝会话（`flow_<rid8>_she`）。
  void _openRunSession(String runSheSessionId) {
    final l10n = AppLocalizations.of(context);
    unawaited(openFlowRunSession(
      peerId: widget.peerId,
      runSheSessionId: runSheSessionId,
      title: l10n.flow_runSession,
    ));
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
              if (node.hasSession) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  key: const ValueKey('node-view-session'),
                  icon: const Icon(Icons.forum_outlined),
                  label: Text(l10n.flow_viewSession),
                  onPressed: () {
                    Navigator.pop(context);
                    _openSession(node);
                  },
                ),
              ],
              // P6：节点在等人回答时，弹层里也放一个「去回答」（和卡片上那个
              // 一样打开节点会话并定位待答卡片）。
              if (node.status?.isWaitingForUser == true && node.hasSession) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('node-goto-answer'),
                  icon: const Icon(Icons.question_answer_outlined),
                  label: Text(l10n.flow_gotoAnswer),
                  onPressed: () {
                    Navigator.pop(context);
                    _openSession(node);
                  },
                ),
              ],
              // 运行中改写（F19）：只改还没开始的节点，所以已经开跑或终态的
              // 不显示这个入口。
              if (_canPatch(node)) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('node-patch'),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(l10n.flow_patchNode),
                  onPressed: () {
                    Navigator.pop(context);
                    _patchNode(node);
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 这个节点还能改吗。跑过的、已经有终态的都改不了（F19 的口径）。
  bool _canPatch(FlowNode node) {
    final status = node.status;
    if (status == null) return false;
    if (status != FlowNodeStatus.pending) return false;
    return _run?.status == FlowRunStatus.running;
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// 改写还没开始的节点（F19）。单个叶子改不了，要指向它所在的容器。
  Future<void> _patchNode(FlowNode node) async {
    final l10n = AppLocalizations.of(context);
    final yaml = _run?.yaml ?? '';
    final target = node.isContainer
        ? node
        : flowLocate(_run?.tree ?? const [], node.id)?.parent;
    if (yaml.isEmpty || target == null) {
      _snack(l10n.flow_patchNotFound);
      return;
    }
    final stepsJson = FlowYaml.stepsJsonOf(yaml, target.id);
    if (stepsJson == null) {
      _snack(l10n.flow_patchNotFound);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => Padding(
        padding: EdgeInsets.only(
          left: 12,
          right: 12,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 12,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: FlowYamlEditor(
            yaml: stepsJson,
            hint: '[{"id": "a", "task": {"prompt": "做"}}]',
            applyLabel: l10n.flow_patchApply,
            onApply: (edited, _) async {
              final steps = FlowYaml.stepsFromJson(edited);
              if (steps == null) {
                _snack(l10n.flow_patchNotAList);
                return;
              }
              // 主机按完整 NodeKey 找运行中的节点（`outer/inner`、`loop#2/x`）。
              // 只有顶层容器的 key 才等于 id；嵌在容器 / if 分支里的节点如果只
              // 发 id，主机会把改写记到一个永远用不上的 key 上，回 success:true
              // 却什么都没改。YAML 里的步骤仍按 id 定位，所以上面用 target.id。
              final result = await _client.patch(
                  widget.peerId, widget.runId, target.key, steps);
              if (!mounted) return;
              if (!result.ok) {
                _snack(result.reachable
                    ? (result.error ?? l10n.flow_patchFailed)
                    : l10n.flow_hostNoReply);
                return;
              }
              Navigator.pop(sheet);
              unawaited(_load());
            },
          ),
        ),
      ),
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
          // 走完了才能删：在跑的要先取消（主机那边也会这么回）。
          if (run != null && run.status.isFinished)
            IconButton(
              key: const ValueKey('run-delete'),
              tooltip: AppLocalizations.of(context).flow_deleteRun,
              icon: const Icon(Icons.delete_outline),
              onPressed: _deleteRun,
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
        // P6：运行级惜宝会话（flow_<rid8>_she）。gate / judge 这类流程层面的
        // 卡片都落在这里，从运行页能一步点进去。拿不到 rid8 时不画这个入口。
        if (run.runSessionId != null) ...[
          const SizedBox(height: 8),
          _RunSessionEntry(onTap: () => _openRunSession(run.runSessionId!)),
        ],
        const SizedBox(height: 12),
        FlowNodeTree(
          nodes: run.tree,
          onTapNode: _showNode,
          onOpenSession: _openSession,
          onAnswerGate: _answer,
        ),
      ],
    );
  }
}

/// 顶部「运行会话」入口。
class _RunSessionEntry extends StatelessWidget {
  const _RunSessionEntry({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: OutlinedButton.icon(
        key: const ValueKey('flow-run-session'),
        icon: const Icon(Icons.forum_outlined, size: 18),
        label: Text(l10n.flow_runSession),
        onPressed: onTap,
      ),
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
