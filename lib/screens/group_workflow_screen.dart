import 'dart:async';
import 'package:flutter/material.dart';
import '../models/workflow_models.dart';
import '../services/local_database_service.dart';
import '../services/workflow/workflow_service.dart';
import '../widgets/workflow/workflow_list_tile.dart';
import 'workflow_detail_screen.dart';

/// Group workflow management screen.
///
/// Shows a list of all workflow executions for a given channel,
/// with active workflows pinned at the top. Tapping an item
/// navigates to [WorkflowDetailScreen].
class GroupWorkflowScreen extends StatefulWidget {
  final String channelId;
  final String channelName;
  final VoidCallback? onBack;

  const GroupWorkflowScreen({
    super.key,
    required this.channelId,
    required this.channelName,
    this.onBack,
  });

  @override
  State<GroupWorkflowScreen> createState() => _GroupWorkflowScreenState();
}

class _GroupWorkflowScreenState extends State<GroupWorkflowScreen> {
  late final WorkflowService _workflowService;
  List<WorkflowExecution> _executions = [];
  bool _loading = true;
  StreamSubscription? _updateSub;

  @override
  void initState() {
    super.initState();
    _workflowService = WorkflowService(db: LocalDatabaseService());
    _load();
    // Listen for real-time updates
    _updateSub = _workflowService
        .watchChannelWorkflows(widget.channelId)
        .listen((executions) {
      if (mounted) {
        setState(() => _executions = executions);
      }
    });
  }

  @override
  void dispose() {
    _updateSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final executions =
        await _workflowService.getWorkflowExecutions(widget.channelId);
    if (mounted) {
      setState(() {
        _executions = executions;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBack ?? () => Navigator.pop(context),
        ),
        title: Text('${widget.channelName} - 工作流'),
        elevation: 1,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _executions.isEmpty
              ? _buildEmptyState()
              : _buildList(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_tree_outlined,
              size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            '暂无工作流记录',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey.shade500,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '开启 Flow 模式后，群聊中的工作流执行将记录在此处',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade400,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    // Sort: active workflows first, then by creation time descending
    final sorted = List<WorkflowExecution>.from(_executions)
      ..sort((a, b) {
        final aActive = a.status == WorkflowStatus.running ||
            a.status == WorkflowStatus.pendingApproval;
        final bActive = b.status == WorkflowStatus.running ||
            b.status == WorkflowStatus.pendingApproval;
        if (aActive && !bActive) return -1;
        if (!aActive && bActive) return 1;
        return b.createdAt.compareTo(a.createdAt);
      });

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: sorted.length,
        itemBuilder: (context, index) {
          final execution = sorted[index];
          return WorkflowListTile(
            execution: execution,
            onTap: () => _navigateToDetail(execution),
          );
        },
      ),
    );
  }

  void _navigateToDetail(WorkflowExecution execution) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WorkflowDetailScreen(
          workflowId: execution.id,
          workflowService: _workflowService,
        ),
      ),
    );
  }
}
