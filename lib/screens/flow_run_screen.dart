import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/flow_models.dart';
import '../peer/peer_approval_payload.dart';
import '../peer/services/flow_session_open.dart';
import '../peer/services/hub_flow.dart';
import '../peer/services/peer_connection.dart';
import '../peer/services/peer_connection_manager.dart';
import '../services/approval/pending_approval_hub.dart';
import '../services/approval/pending_approval_item.dart';
import '../utils/layout_utils.dart';
import '../widgets/flow/flow_loop_rounds.dart';
import '../widgets/flow/flow_node_tree.dart';
import '../widgets/flow/flow_yaml.dart';
import '../widgets/flow/flow_yaml_editor.dart';

/// P6：「去回答」要定位到那张待答卡片。孤儿卡落的确定性消息行是
/// `peer_form_<approval_id>`；提醒项 id 是 `action:<form_id>`（form_id 就等于
/// approval_id）。找不到待答项时返回 null —— 只打开会话，不强求高亮。
///
/// A6-8：动作确认提醒也可能排在表单卡前面，直接取第一条会把高亮指到
/// 错误的气泡。表单提醒（[PendingApprovalItem.isForm]）优先，其余留作兜底。
@visibleForTesting
String? pendingFlowFormMessageId(String channelId) {
  const actionPrefix = 'action:';
  const formCardPrefix = 'peer_form_';
  String? cardIdFor(PendingApprovalItem item) {
    final mid = item.messageId;
    // 已经落在确定性表单行上时直接用它，别再按提醒 id 另拼一个。
    if (mid != null && mid.startsWith(formCardPrefix)) return mid;
    if (item.id.startsWith(actionPrefix)) {
      final formId = item.id.substring(actionPrefix.length);
      if (formId.isNotEmpty) {
        return PeerApprovalPayload.formCardMessageId(formId);
      }
    }
    return mid != null && mid.isNotEmpty ? mid : null;
  }

  String? fallback;
  for (final item in PendingApprovalHub.instance.itemsForChannel(channelId)) {
    final mid = item.messageId;
    // 从 DB hydrate 出来的表单提醒没有 interactionType，按确定性消息行
    // `peer_form_<form_id>` 也能认出来。
    final isFormCard =
        item.isForm || (mid != null && mid.startsWith(formCardPrefix));
    if (isFormCard) {
      final formCard = cardIdFor(item);
      if (formCard != null) return formCard;
    }
    if (mid != null && mid.isNotEmpty) {
      fallback ??= mid;
    } else {
      final id = item.id;
      if (id.startsWith(actionPrefix)) {
        final formId = id.substring(actionPrefix.length);
        if (formId.isNotEmpty) {
          fallback ??= PeerApprovalPayload.formCardMessageId(formId);
        }
      }
    }
  }
  return fallback;
}

/// 工作流运行视图（方案 C.2）：节点树叠状态，随 `flow.*` 事件更新；
/// 关卡直接点选项作答；点节点看完整输出，有会话的可以"查看会话"。
///
/// 宽屏把点开的组件放在右侧栏，树还留在左边；窄屏仍用底部弹层。
class FlowRunScreen extends StatefulWidget {
  const FlowRunScreen({
    super.key,
    required this.peerId,
    required this.runId,
    this.title,
    this.client,
    this.onOpenSession,
    this.onDeleted,
    this.onClose,
    this.embedded = false,
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

  /// 嵌在工作流右侧时，返回关掉这一层，而不是 pop 整个工作流。
  final VoidCallback? onClose;

  /// 作为工作流右侧的当前记录。没有返回按钮，换一条记录就换这一页。
  final bool embedded;

  @override
  State<FlowRunScreen> createState() => _FlowRunScreenState();
}

class _FlowRunScreenState extends State<FlowRunScreen> {
  /// 右边还能放下一条组件栏时才分栏。再窄就退回底部弹层，避免把树挤没。
  static const double _sidePaneMinWidth = 600;

  late final HubFlow _client = widget.client ?? HubFlow();
  StreamSubscription<FlowEvent>? _sub;
  StreamSubscription<PeerConnectionEvent>? _connSub;
  Timer? _refetch;
  FlowRunView? _run;
  bool _loading = true;
  bool _loadFailed = false;
  Future<void>? _inFlightLoad;
  bool _reloadQueued = false;

  /// 事件里只有 session_id、没有 agent：先别建空壳频道，等 refetch 补上
  /// agent 再打开（A8-3）。
  ({
    String sessionId,
    String title,
    String? highlightMessageId
  })? _pendingSessionOpen;

  /// 宽屏右侧栏正在看的节点。按 key 跟最新的树对齐，状态刷新后栏里也是新的。
  String? _selectedKey;
  double _bodyWidth = 0;

  @override
  void initState() {
    super.initState();
    _sub = _client.runEvents(widget.peerId).listen(_onEvent);
    // 测试注入了假客户端时不要碰真实连接管理器。
    if (widget.client == null) {
      _connSub = PeerConnectionManager.instance.events.listen((event) {
        if (!mounted || event.peerId != widget.peerId) return;
        if (event.type != PeerConnectionEventType.connected) return;
        // 废连接被丢掉并重连成功后，把刚才失败的那次运行重新拉回来。
        if (_loadFailed || (_run == null && !_loading)) {
          unawaited(_load());
        }
      });
    }
    unawaited(_load());
  }

  @override
  void didUpdateWidget(FlowRunScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runId != widget.runId) _selectedKey = null;
  }

  @override
  void dispose() {
    _refetch?.cancel();
    _sub?.cancel();
    _connSub?.cancel();
    super.dispose();
  }

  Future<void> _load() {
    final inFlight = _inFlightLoad;
    if (inFlight != null) {
      _reloadQueued = true;
      return inFlight;
    }
    final future = _loadOnce();
    _inFlightLoad = future;
    return future.whenComplete(() {
      if (identical(_inFlightLoad, future)) _inFlightLoad = null;
      if (!_reloadQueued || !mounted) return;
      _reloadQueued = false;
      unawaited(_load());
    });
  }

  Future<void> _loadOnce() async {
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
    // 事件先到、agent 还没同步下来时挂起的「查看会话」，重拉成功后再打开。
    _retryPendingSessionOpen();
  }

  /// 在最新的运行树里按 key / session_id 找同一个节点的 agent。
  /// 弹层里的 node 可能是旧 `_run` 的快照；重拉回来后树上的 agentId 才是权威。
  String _agentIdForSession(FlowNode node) {
    final own = node.agentId?.trim() ?? '';
    if (own.isNotEmpty) return own;
    final run = _run;
    if (run == null) return '';
    for (final root in run.tree) {
      final current = root.find((candidate) =>
          candidate.key == node.key ||
          (node.sessionId != null &&
              candidate.sessionId == node.sessionId &&
              candidate.agentId != null &&
              candidate.agentId!.isNotEmpty));
      if (current != null) return current.agentId?.trim() ?? '';
    }
    return '';
  }

  void _retryPendingSessionOpen() {
    final pending = _pendingSessionOpen;
    if (pending == null || !mounted || _run == null) return;
    final node = _run!.tree
        .map((root) => root.find((candidate) =>
            candidate.sessionId == pending.sessionId &&
            (candidate.agentId?.isNotEmpty ?? false)))
        .whereType<FlowNode>()
        .firstOrNull;
    if (node == null) return;
    final agentId = node.agentId!.trim();
    if (agentId.isEmpty) return;
    _pendingSessionOpen = null;
    unawaited(openFlowSession(
      peerId: widget.peerId,
      sessionId: pending.sessionId,
      remoteAgentId: agentId,
      title: pending.title,
      highlightMessageId: pending.highlightMessageId,
    ));
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
            agentId: event.agentId,
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
    if (!mounted) return;
    if (widget.onClose != null) {
      widget.onClose!();
      return;
    }
    if (widget.embedded) return;
    if (Navigator.of(context).canPop()) {
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
    // 只有主机发下来的真节点会话（`flow_...`）能拼 `psess_` 频道。旧运行 /
    // 群运行的条目可能还留着 `flow:<rid>:<node>` / `group:<gid>:<sid>:...`
    // 这类引擎槽位 key；硬拼会建出一个永远没有消息的假会话。格式不合法时
    // 留在运行页。
    final guardedSessionId = flowFoldedSessionId(node.sessionId ?? '');
    if (guardedSessionId == null) return;
    final l10n = AppLocalizations.of(context);
    final title = l10n.flow_sessionBanner(node.id);
    final highlightMessageId = node.status?.isWaitingForUser == true
        ? pendingFlowFormMessageId(flowSessionChannelId(guardedSessionId))
        : null;
    // 旧主机 / 事件帧可能只给 session_id，不给 agent_id（H8-11 之前）。
    // 拿空 agent 打开会建出一条没有成员的空壳频道；先用运行树里同 key
    // 节点的 agentId，仍拿不到就挂起，等 refetch 把 agent 带回来再打开。
    final agentId = _agentIdForSession(node);
    if (agentId.isEmpty) {
      _pendingSessionOpen = (
        sessionId: guardedSessionId,
        title: title,
        highlightMessageId: highlightMessageId,
      );
      _snack(l10n.flow_sessionPreparing);
      // 不等事件自带的 400ms 合批窗口，立刻重拉一次。
      _refetch?.cancel();
      unawaited(_load());
      return;
    }
    // 覆盖入口也拿补全后的 agentId，不能让它用空成员建频道。
    final resolvedNode = (node.agentId ?? '').trim() == agentId
        ? node
        : node.copyWith(agentId: agentId);
    final override = widget.onOpenSession;
    if (override != null) {
      override(resolvedNode);
      return;
    }
    unawaited(openFlowSession(
      peerId: widget.peerId,
      sessionId: guardedSessionId,
      remoteAgentId: agentId,
      title: title,
      highlightMessageId: highlightMessageId,
    ));
  }

  /// 顶部「运行会话」：打开第一个已经跑起来的节点自己的会话。
  ///
  /// 节点的 `agent_id` 是模板里配的执行者（design 经常不是惜宝）。聊天记录
  /// 在那条节点会话上，不在 `flow_<tag>_she`。节点还没会话时才打开惜宝那条。
  void _openRunConversation(FlowRunView run) {
    final l10n = AppLocalizations.of(context);
    final target =
        flowRunConversationTarget(run.tree, sheSessionId: run.runSessionId);
    if (target == null) return;
    final node = _nodeForSession(run, target.sessionId);
    if (node != null) {
      _openSession(node);
      return;
    }
    unawaited(openFlowRunSession(
      peerId: widget.peerId,
      runSheSessionId: target.sessionId,
      title: l10n.flow_runSession,
    ));
  }

  FlowNode? _nodeForSession(FlowRunView run, String sessionId) {
    for (final root in run.tree) {
      final node = root.find((candidate) =>
          flowFoldedSessionId(candidate.sessionId ?? '') == sessionId);
      if (node != null) return node;
    }
    return null;
  }

  bool _useSidePane(double width) =>
      LayoutUtils.isDesktopLayout(context) && width >= _sidePaneMinWidth;

  double _sidePaneWidth(double total) {
    final preferred = total * 0.38;
    final width = preferred < 260
        ? 260.0
        : preferred > 420
            ? 420.0
            : preferred;
    final max = total - 300;
    return width > max ? max : width;
  }

  FlowNode? _nodeByKey(String key) {
    final run = _run;
    if (run == null) return null;
    for (final root in run.tree) {
      final found = root.find((node) => node.key == key);
      if (found != null) return found;
    }
    return null;
  }

  void _showNode(FlowNode node) {
    if (_useSidePane(_bodyWidth)) {
      setState(() => _selectedKey = node.key);
      return;
    }
    _showNodeSheet(node);
  }

  void _showNodeSheet(FlowNode node) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.55,
          maxChildSize: 0.9,
          builder: (context, controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.all(16),
            children: [
              _NodeDetailContent(
                node: node,
                showTitle: true,
                canPatch: _canPatch(node),
                onOpenSession: () {
                  Navigator.pop(sheetContext);
                  _openSession(node);
                },
                onOpenChildSession: (child) {
                  Navigator.pop(sheetContext);
                  _openSession(child);
                },
                onPatch: () {
                  Navigator.pop(sheetContext);
                  unawaited(_patchNode(node));
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sidePane(FlowNode node) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return DecoratedBox(
      key: const ValueKey('flow-node-detail-pane'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(left: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: kToolbarHeight,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    flowKindTitle(l10n, node),
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  key: const ValueKey('flow-node-detail-close'),
                  tooltip: l10n.flow_drawerClose,
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _selectedKey = null),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _NodeDetailContent(
                  node: node,
                  showTitle: false,
                  canPatch: _canPatch(node),
                  onOpenSession: () => _openSession(node),
                  onOpenChildSession: _openSession,
                  onPatch: () => unawaited(_patchNode(node)),
                ),
              ],
            ),
          ),
        ],
      ),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        _bodyWidth = constraints.maxWidth;
        return _scaffold(run);
      },
    );
  }

  Widget _scaffold(FlowRunView? run) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded && widget.onClose == null,
        leading: widget.onClose == null
            ? null
            : BackButton(onPressed: widget.onClose),
        title: Text(widget.title ?? AppLocalizations.of(context).flow_runTitle),
        actions: [
          // 运行相关的动作都在顶部状态条上：取消在明处，删除收进 `⋯`，
          // 避免两个危险按钮挨着被误点。这里只留全局刷新。
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
    final selectedKey = _selectedKey;
    final selected = _useSidePane(_bodyWidth) && selectedKey != null
        ? _nodeByKey(selectedKey)
        : null;
    if (selectedKey != null && selected == null && _useSidePane(_bodyWidth)) {
      final missing = selectedKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selectedKey != missing) return;
        if (_nodeByKey(missing) != null) return;
        setState(() => _selectedKey = null);
      });
    }
    final list = ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _RunStatusStrip(
          run: run,
          onCancel: _cancel,
          onDelete: _deleteRun,
        ),
        // 运行级失败 / 取消原因。主机把 Failed 的 error 和 Cancel 的 reason
        // 都写进 `flow_run_get_resp.error`；之前只有节点级 error 被渲染，
        // 用户主动停止、看门狗按卡住收敛时都只看到「已取消」却不知道为什么。
        // 只在终态的失败 / 取消显示：主机在非终态也会写 `run.error`
        // （`on_error: continue` 的失败分支、宽限期、预算告警），运行中或
        // 已成功的运行挂一张「失败原因」会误导用户。
        if ((run.status == FlowRunStatus.failed ||
                run.status == FlowRunStatus.cancelled) &&
            run.error != null &&
            run.error!.isNotEmpty) ...[
          const SizedBox(height: 8),
          _RunErrorCard(run: run),
        ],
        // 群运行的对话在群里，不画这个入口（runSessionId 为空）。
        // 点进去优先打开节点自己的 agent 会话，而不是惜宝私聊。
        if (run.runSessionId != null) ...[
          const SizedBox(height: 8),
          _RunSessionEntry(onTap: () => _openRunConversation(run)),
        ],
        const SizedBox(height: 12),
        FlowNodeTree(
          nodes: run.tree,
          onTapNode: _showNode,
          onOpenSession: _openSession,
          onAnswerGate: _answer,
          selectedIds: selected == null ? const {} : {selected.id},
        ),
      ],
    );
    if (selected == null) return list;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: list),
        SizedBox(width: _sidePaneWidth(_bodyWidth), child: _sidePane(selected)),
      ],
    );
  }
}

/// 点开一个组件后看到的输出和动作。宽屏放进右侧栏，窄屏放进底部弹层。
class _NodeDetailContent extends StatelessWidget {
  const _NodeDetailContent({
    required this.node,
    required this.showTitle,
    required this.canPatch,
    required this.onOpenSession,
    required this.onPatch,
    this.onOpenChildSession,
  });

  final FlowNode node;
  final bool showTitle;
  final bool canPatch;
  final VoidCallback onOpenSession;
  final VoidCallback onPatch;
  final void Function(FlowNode node)? onOpenChildSession;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showTitle)
          Text(flowKindTitle(l10n, node), style: theme.textTheme.titleMedium),
        if (node.status != null) ...[
          if (showTitle) const SizedBox(height: 4),
          Text(l10n.flow_statusLine(flowStatusLabel(l10n, node.status!)) +
              (node.attempt > 1 ? l10n.flow_attemptSuffix(node.attempt) : '')),
        ],
        if (node.error != null) ...[
          const SizedBox(height: 12),
          SelectableText(node.error!,
              style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (node.text != null) ...[
          const SizedBox(height: 12),
          SelectableText(node.text!),
        ],
        if (node.iterations.isNotEmpty) ...[
          const SizedBox(height: 12),
          FlowLoopRounds(
            node: node,
            onOpenSession: onOpenChildSession,
          ),
        ],
        // 只摆当前适用的 1~2 个动作：等回答时「去回答」优先，
        // 其余时候才看「查看会话」；两者不再同时出现。
        if (node.hasSession) ...[
          const SizedBox(height: 16),
          if (node.status?.isWaitingForUser == true)
            OutlinedButton.icon(
              key: const ValueKey('node-goto-answer'),
              icon: const Icon(Icons.question_answer_outlined),
              label: Text(l10n.flow_gotoAnswer),
              onPressed: onOpenSession,
            )
          else
            OutlinedButton.icon(
              key: const ValueKey('node-view-session'),
              icon: const Icon(Icons.forum_outlined),
              label: Text(l10n.flow_viewSession),
              onPressed: onOpenSession,
            ),
        ],
        // 运行中改写（F19）：只改还没开始的节点，所以已经开跑或终态的
        // 不显示这个入口。
        if (canPatch) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('node-patch'),
            icon: const Icon(Icons.edit_outlined),
            label: Text(l10n.flow_patchNode),
            onPressed: onPatch,
          ),
        ],
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

class _RunStatusStrip extends StatelessWidget {
  const _RunStatusStrip({
    required this.run,
    required this.onCancel,
    required this.onDelete,
  });

  final FlowRunView run;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

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
    final started = run.startedMs;
    final elapsed = started != null && started > 0
        ? DateTime.now()
            .difference(DateTime.fromMillisecondsSinceEpoch(started))
        : null;
    String? elapsedLabel;
    if (elapsed != null && !run.status.isFinished) {
      elapsedLabel = l10n.flow_runElapsed(_durationLabel(elapsed));
    }
    return Material(
      key: const ValueKey('run-status-strip'),
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(Icons.account_tree_outlined, color: color, size: 18),
            Text(label,
                style: theme.textTheme.titleSmall?.copyWith(color: color)),
            Text(l10n.flow_tasksUsed(run.tasksUsed),
                style: theme.textTheme.bodySmall),
            if (elapsedLabel != null)
              Text(elapsedLabel, style: theme.textTheme.bodySmall),
            if (!run.status.isFinished)
              Tooltip(
                message: l10n.flow_cancelRun,
                child: OutlinedButton.icon(
                  key: const ValueKey('run-cancel'),
                  onPressed: onCancel,
                  icon: const Icon(Icons.stop_circle_outlined, size: 16),
                  label: Text(l10n.flow_cancelRun),
                ),
              ),
            PopupMenuButton<String>(
              key: const ValueKey('run-more'),
              tooltip: l10n.flow_runMore,
              onSelected: (value) {
                if (value == 'delete') onDelete();
              },
              itemBuilder: (context) => [
                PopupMenuItem<String>(
                  key: const ValueKey('run-delete'),
                  value: 'delete',
                  enabled: run.status.isFinished,
                  child: Text(l10n.flow_deleteRun),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 数字时长（hh:mm:ss），不带语言，交给 [AppLocalizations.flow_runElapsed]
  /// 配「已用 …」的文案。
  static String _durationLabel(Duration elapsed) {
    final hours = elapsed.inHours;
    final minutes = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0
        ? '${hours.toString().padLeft(2, '0')}:$minutes:$seconds'
        : '$minutes:$seconds';
  }
}

/// 运行级失败 / 取消原因。`failed` 用错误色，`cancelled` 用中性色——
/// 用户主动停止不该渲染成一张红色失败卡。
class _RunErrorCard extends StatelessWidget {
  const _RunErrorCard({required this.run});

  final FlowRunView run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = run.status == FlowRunStatus.failed;
    // 正文 / 图标必须可读：`outline` 是分隔灰（亮色对比度 1.14:1），
    // `onSurfaceVariant` 在亮色被压成 grey500（2.41:1）也不达标。
    // 取消态用 onSurface（亮 14.2:1 / 暗 >10:1），failed 仍用 error。
    final foreground =
        failed ? theme.colorScheme.error : theme.colorScheme.onSurface;
    final surface = failed
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.surfaceContainerHighest;
    return Container(
      key: const ValueKey('run-error-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            failed ? Icons.error_outline : Icons.info_outline,
            size: 16,
            color: foreground,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              run.error!,
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}
