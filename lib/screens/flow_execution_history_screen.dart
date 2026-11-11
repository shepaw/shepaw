import 'package:flutter/material.dart';

import '../peer/services/hub_flow.dart';
import '../widgets/flow/flow_runs_pane.dart';
import 'flow_run_screen.dart';

/// 某个流程的执行历史。
///
/// 列表用开跑时填的标题辨认每一次运行。点一条打开运行详情，
/// 详情的返回回到这份列表，而不是关掉整个执行历史。
class FlowExecutionHistoryScreen extends StatefulWidget {
  const FlowExecutionHistoryScreen({
    super.key,
    required this.client,
    required this.peerId,
    required this.scope,
    required this.flowName,
    this.initialRunId,
    this.initialTitle,
    this.initialInstanceId,
    this.initialInstanceScope,
    this.initialRunScope,
    required this.onClose,
    this.onBindBack,
    this.onRunOpenChanged,
  });

  final HubFlow client;
  final String peerId;
  final String scope;
  final String flowName;

  /// 从「待审批」或刚开跑进来时，直接打开这一次，返回仍回到列表。
  final String? initialRunId;
  final String? initialTitle;

  /// 刚开跑时从 `flow_run_start_resp` 带来的三层坐标。点历史里的旧运行时
  /// 由 `FlowRunScreen` 自己从 run / 产物 scope 反解，不沿用上一次的坐标。
  final String? initialInstanceId;
  final String? initialInstanceScope;
  final String? initialRunScope;

  final VoidCallback onClose;

  /// 把「从详情退回列表」交给外层，系统返回键能先退这一层。
  /// 传 null 表示这一页要卸掉了。
  final void Function(VoidCallback? back)? onBindBack;

  final ValueChanged<bool>? onRunOpenChanged;

  @override
  State<FlowExecutionHistoryScreen> createState() =>
      _FlowExecutionHistoryScreenState();
}

class _FlowExecutionHistoryScreenState
    extends State<FlowExecutionHistoryScreen> {
  String? _runId;
  String? _title;
  String? _instanceId;
  String? _instanceScope;
  String? _runScope;

  @override
  void initState() {
    super.initState();
    _runId = widget.initialRunId;
    _title = widget.initialTitle;
    _instanceId = widget.initialInstanceId;
    _instanceScope = widget.initialInstanceScope;
    _runScope = widget.initialRunScope;
    widget.onBindBack?.call(_runId == null ? null : _backToList);
    if (_runId != null) widget.onRunOpenChanged?.call(true);
  }

  @override
  void dispose() {
    widget.onBindBack?.call(null);
    widget.onRunOpenChanged?.call(false);
    super.dispose();
  }

  void _openRun(String runId, String title) {
    setState(() {
      _runId = runId;
      _title = title;
      _instanceId = null;
      _instanceScope = null;
      _runScope = null;
    });
    widget.onBindBack?.call(_backToList);
    widget.onRunOpenChanged?.call(true);
  }

  void _backToList() {
    if (!mounted || _runId == null) return;
    setState(() {
      _runId = null;
      _title = null;
    });
    widget.onBindBack?.call(null);
    widget.onRunOpenChanged?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    final runId = _runId;
    if (runId != null) {
      return FlowRunScreen(
        key: ValueKey('flow-execution-run-$runId'),
        peerId: widget.peerId,
        runId: runId,
        title: _title,
        client: widget.client,
        instanceId: _instanceId,
        instanceScope: _instanceScope,
        runScope: _runScope,
        onClose: _backToList,
        onDeleted: _backToList,
      );
    }
    return FlowRunsPane(
      client: widget.client,
      peerId: widget.peerId,
      scope: widget.scope,
      name: widget.flowName,
      executionHistory: true,
      onClose: widget.onClose,
      onOpenRun: _openRun,
    );
  }
}
