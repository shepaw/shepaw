import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/agent_conversation_request.dart';
import '../providers/app_state.dart';

class AgentApprovalScreen extends StatefulWidget {
  const AgentApprovalScreen({Key? key}) : super(key: key);

  @override
  State<AgentApprovalScreen> createState() => _AgentApprovalScreenState();
}

class _AgentApprovalScreenState extends State<AgentApprovalScreen> {
  bool _isLoading = true;
  List<AgentConversationRequest> _requests = [];
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadPendingRequests();
  }

  Future<void> _loadPendingRequests() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final appState = Provider.of<AppState>(context, listen: false);
      final requests = await appState.getPendingApprovals();

      setState(() {
        _requests = requests;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _approveRequest(AgentConversationRequest request) async {
    try {
      final appState = Provider.of<AppState>(context, listen: false);
      await appState.approveConversation(request.id);

      // 显示成功提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ 已批准 Agent 对话'),
            backgroundColor: Colors.green,
          ),
        );
        // 刷新列表
        _loadPendingRequests();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('批准失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _rejectRequest(AgentConversationRequest request) async {
    // 显示拒绝原因对话框
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => _RejectReasonDialog(),
    );

    if (reason == null) return; // 用户取消

    try {
      final appState = Provider.of<AppState>(context, listen: false);
      await appState.rejectConversation(request.id, reason: reason);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ 已拒绝 Agent 对话'),
            backgroundColor: Colors.orange,
          ),
        );
        // 刷新列表
        _loadPendingRequests();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('拒绝失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent 对话确认'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadPendingRequests,
            tooltip: '刷新',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text('加载失败', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(_errorMessage!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadPendingRequests,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_requests.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle_outline, size: 64, color: Colors.green),
            const SizedBox(height: 16),
            Text(
              '没有待确认的请求',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text('所有 Agent 对话请求都已处理'),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadPendingRequests,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _requests.length,
        itemBuilder: (context, index) {
          final request = _requests[index];
          return _RequestCard(
            request: request,
            onApprove: () => _approveRequest(request),
            onReject: () => _rejectRequest(request),
          );
        },
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  final AgentConversationRequest request;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _RequestCard({
    Key? key,
    required this.request,
    required this.onApprove,
    required this.onReject,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题
            Row(
              children: [
                const Icon(Icons.notifications_active, color: Colors.orange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Agent 对话请求',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                Text(
                  request.timeAgo,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey,
                      ),
                ),
              ],
            ),
            const Divider(height: 24),

            // Agent 信息
            _buildAgentRow(
              context,
              label: '发起者',
              name: request.requesterName ?? request.requesterId,
              avatar: request.requesterAvatar ?? '🤖',
            ),
            const SizedBox(height: 12),
            const Center(
              child: Icon(Icons.arrow_downward, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            _buildAgentRow(
              context,
              label: '目标',
              name: request.targetName ?? request.targetId,
              avatar: request.targetAvatar ?? '🤖',
            ),

            // 消息内容
            if (request.message.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '消息内容:',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey[600],
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      request.message,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],

            // 操作按钮
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onReject,
                    icon: const Icon(Icons.close, color: Colors.red),
                    label: const Text(
                      '拒绝',
                      style: TextStyle(color: Colors.red),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: onApprove,
                    icon: const Icon(Icons.check),
                    label: const Text('批准'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAgentRow(
    BuildContext context, {
    required String label,
    required String name,
    required String avatar,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 60,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                ),
          ),
        ),
        Text(
          avatar,
          style: const TextStyle(fontSize: 32),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            name,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
        ),
      ],
    );
  }
}

class _RejectReasonDialog extends StatefulWidget {
  @override
  State<_RejectReasonDialog> createState() => _RejectReasonDialogState();
}

class _RejectReasonDialogState extends State<_RejectReasonDialog> {
  final _controller = TextEditingController();
  String? _selectedReason;

  final List<String> _commonReasons = [
    '不需要此对话',
    'Agent 权限不足',
    '暂时不允许',
    '安全原因',
    '其他原因',
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('拒绝原因'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('请选择或输入拒绝原因:'),
          const SizedBox(height: 16),
          ..._commonReasons.map((reason) => RadioListTile<String>(
                title: Text(reason),
                value: reason,
                groupValue: _selectedReason,
                onChanged: (value) {
                  setState(() {
                    _selectedReason = value;
                    if (value != '其他原因') {
                      _controller.text = value!;
                    } else {
                      _controller.clear();
                    }
                  });
                },
                dense: true,
              )),
          if (_selectedReason == '其他原因') ...[
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                hintText: '请输入原因',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: () {
            final reason = _controller.text.trim();
            if (reason.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请输入拒绝原因')),
              );
              return;
            }
            Navigator.pop(context, reason);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
