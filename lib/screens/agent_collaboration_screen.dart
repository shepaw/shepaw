import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/agent.dart';
import '../services/agent_collaboration_service.dart';
import '../services/local_api_service.dart';
import '../services/logger_service.dart';
import '../services/error_handler_service.dart';

/// Agent 协作界面
///
/// 实验性功能：提供 Agent 协作任务创建和执行界面
class AgentCollaborationScreen extends StatefulWidget {
  final LocalApiService apiService;

  const AgentCollaborationScreen({
    Key? key,
    required this.apiService,
  }) : super(key: key);

  @override
  State<AgentCollaborationScreen> createState() => _AgentCollaborationScreenState();
}

class _AgentCollaborationScreenState extends State<AgentCollaborationScreen> {
  late final AgentCollaborationService _collaborationService;
  late final ErrorHandlerService _errorHandler;
  final _logger = LoggerService();

  final _formKey = GlobalKey<FormState>();
  final _taskNameController = TextEditingController();
  final _taskDescriptionController = TextEditingController();
  final _messageController = TextEditingController();

  List<Agent> _availableAgents = [];
  List<Agent> _selectedAgents = [];
  CollaborationStrategy _selectedStrategy = CollaborationStrategy.sequential;
  bool _loading = false;
  CollaborationResult? _lastResult;

  @override
  void initState() {
    super.initState();
    _collaborationService = AgentCollaborationService(widget.apiService, _logger);
    _errorHandler = ErrorHandlerService(_logger);
    _loadAgents();
  }

  @override
  void dispose() {
    _taskNameController.dispose();
    _taskDescriptionController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _loadAgents() async {
    try {
      final agents = await widget.apiService.listAgents();
      setState(() {
        _availableAgents = agents;
      });
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        _errorHandler.handleError(context, e, title: l10n.collaboration_loadAgentFailed);
      }
    }
  }

  Future<void> _executeCollaboration() async {
    if (!_formKey.currentState!.validate()) return;
    final l10n = AppLocalizations.of(context);
    if (_selectedAgents.isEmpty) {
      _errorHandler.showWarning(context, l10n.collaboration_selectAgentWarning);
      return;
    }

    setState(() => _loading = true);

    try {
      // 创建协作任务
      final task = await _collaborationService.createCollaborationTask(
        taskName: _taskNameController.text,
        taskDescription: _taskDescriptionController.text,
        agentIds: _selectedAgents.map((a) => a.id).toList(),
        initiatorId: 'user',
        strategy: _selectedStrategy,
      );

      // 执行任务
      final result = await _collaborationService.executeCollaboration(
        task,
        _messageController.text,
      );

      setState(() {
        _lastResult = result;
        _loading = false;
      });

      if (result.status == CollaborationStatus.completed) {
        _errorHandler.showSuccess(context, l10n.collaboration_success);
      } else {
        _errorHandler.showWarning(context, l10n.collaboration_taskFailed(result.error ?? ''));
      }
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        _errorHandler.handleError(context, e, title: l10n.collaboration_executeFailed);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.collaboration_title),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => _showHelp(),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 协作说明卡片
            Card(
              color: Colors.purple.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.groups, size: 32, color: Colors.purple),
                        const SizedBox(width: 12),
                        Text(
                          l10n.collaboration_title,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.purple.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.collaboration_description,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // 任务名称
            TextFormField(
              controller: _taskNameController,
              decoration: InputDecoration(
                labelText: l10n.collaboration_taskName,
                hintText: l10n.collaboration_taskNameHint,
                prefixIcon: const Icon(Icons.title),
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return l10n.collaboration_taskNameRequired;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // 任务描述
            TextFormField(
              controller: _taskDescriptionController,
              decoration: InputDecoration(
                labelText: l10n.collaboration_taskDescription,
                hintText: l10n.collaboration_taskDescriptionHint,
                prefixIcon: const Icon(Icons.description),
                border: const OutlineInputBorder(),
              ),
              maxLines: 3,
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return l10n.collaboration_taskDescriptionRequired;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // 初始消息
            TextFormField(
              controller: _messageController,
              decoration: InputDecoration(
                labelText: l10n.collaboration_initialMessage,
                hintText: l10n.collaboration_initialMessageHint,
                prefixIcon: const Icon(Icons.message),
                border: const OutlineInputBorder(),
              ),
              maxLines: 3,
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return l10n.collaboration_initialMessageRequired;
                }
                return null;
              },
            ),
            const SizedBox(height: 24),

            // 选择协作策略
            Text(
              l10n.collaboration_strategy,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ...CollaborationStrategy.values.map((strategy) {
              return RadioListTile<CollaborationStrategy>(
                value: strategy,
                groupValue: _selectedStrategy,
                onChanged: (value) {
                  setState(() => _selectedStrategy = value!);
                },
                title: Text(_getStrategyName(strategy)),
                subtitle: Text(_getStrategyDescription(strategy)),
              );
            }),
            const SizedBox(height: 24),

            // 选择 Agent
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l10n.collaboration_selectAgent,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  l10n.collaboration_selectedCount(_selectedAgents.length, _availableAgents.length),
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_availableAgents.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(l10n.collaboration_noAgents),
                ),
              )
            else
              ..._availableAgents.map((agent) {
                final isSelected = _selectedAgents.contains(agent);
                return CheckboxListTile(
                  value: isSelected,
                  onChanged: (selected) {
                    setState(() {
                      if (selected == true) {
                        _selectedAgents.add(agent);
                      } else {
                        _selectedAgents.remove(agent);
                      }
                    });
                  },
                  title: Text(agent.name),
                  subtitle: Text(agent.description ?? l10n.collaboration_noDescription),
                  secondary: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Text(agent.name[0]),
                  ),
                );
              }),
            const SizedBox(height: 24),

            // 执行按钮
            ElevatedButton(
              onPressed: _loading ? null : _executeCollaboration,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: Colors.purple,
              ),
              child: _loading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(l10n.collaboration_start, style: const TextStyle(fontSize: 16)),
            ),

            // 结果展示
            if (_lastResult != null) ...[
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 16),
              _buildResultSection(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResultSection() {
    if (_lastResult == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              _lastResult!.status == CollaborationStatus.completed
                  ? Icons.check_circle
                  : Icons.error,
              color: _lastResult!.status == CollaborationStatus.completed
                  ? Colors.green
                  : Colors.red,
            ),
            const SizedBox(width: 8),
            Text(
              l10n.collaboration_result,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // 最终输出
        if (_lastResult!.finalOutput != null) ...[
          Text(
            l10n.collaboration_finalOutput,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(_lastResult!.finalOutput!),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // 各Agent结果
        if (_lastResult!.results.isNotEmpty) ...[
          Text(
            l10n.collaboration_agentResults,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          ..._lastResult!.results.entries.map((entry) {
            return Card(
              child: ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Text(entry.key[0]),
                ),
                title: Text(entry.key),
                subtitle: Text(entry.value),
              ),
            );
          }),
        ],
      ],
    );
  }

  String _getStrategyName(CollaborationStrategy strategy) {
    final l10n = AppLocalizations.of(context);
    switch (strategy) {
      case CollaborationStrategy.sequential:
        return l10n.collaboration_strategySequential;
      case CollaborationStrategy.parallel:
        return l10n.collaboration_strategyParallel;
      case CollaborationStrategy.voting:
        return l10n.collaboration_strategyVoting;
      case CollaborationStrategy.pipeline:
        return l10n.collaboration_strategyPipeline;
    }
  }

  String _getStrategyDescription(CollaborationStrategy strategy) {
    final l10n = AppLocalizations.of(context);
    switch (strategy) {
      case CollaborationStrategy.sequential:
        return l10n.collaboration_strategySequentialDesc;
      case CollaborationStrategy.parallel:
        return l10n.collaboration_strategyParallelDesc;
      case CollaborationStrategy.voting:
        return l10n.collaboration_strategyVotingDesc;
      case CollaborationStrategy.pipeline:
        return l10n.collaboration_strategyPipelineDesc;
    }
  }

  void _showHelp() {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.collaboration_helpTitle),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.collaboration_strategySequential, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text('${l10n.collaboration_helpSequential}\n'),
              Text(l10n.collaboration_strategyParallel, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text('${l10n.collaboration_helpParallel}\n'),
              Text(l10n.collaboration_strategyVoting, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text('${l10n.collaboration_helpVoting}\n'),
              Text(l10n.collaboration_strategyPipeline, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(l10n.collaboration_helpPipeline),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.common_ok),
          ),
        ],
      ),
    );
  }
}
