import 'package:flutter/material.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../services/local_api_service.dart';
import '../services/logger_service.dart';
import '../utils/exceptions.dart';
import '../widgets/avatar_image.dart';
import 'chat_screen.dart';

/// Agent 详情/添加/编辑页面
class AgentDetailScreen extends StatefulWidget {
  final Agent? agent; // null 表示新建模式

  /// 若为 true，打开即进入编辑模式（仅在 agent != null 时有效）
  final bool initialEditMode;

  const AgentDetailScreen({Key? key, this.agent, this.initialEditMode = false}) : super(key: key);

  @override
  State<AgentDetailScreen> createState() => _AgentDetailScreenState();
}

class _AgentDetailScreenState extends State<AgentDetailScreen> {
  final _formKey = GlobalKey<FormState>();
  final LocalApiService _apiService = LocalApiService();

  late TextEditingController _nameController;
  late TextEditingController _typeController;
  late TextEditingController _avatarController;
  late TextEditingController _maxToolRoundsController;
  late TextEditingController _taskTimeoutController;
  String _selectedStatus = 'online';

  bool _isEditing = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _isEditing = widget.agent == null || widget.initialEditMode;
    _nameController = TextEditingController(text: widget.agent?.name ?? '');
    _typeController = TextEditingController(text: widget.agent?.type ?? '');
    _avatarController = TextEditingController(text: widget.agent?.avatar ?? '');
    _selectedStatus = widget.agent?.status.state ?? 'online';
    _maxToolRoundsController = TextEditingController(
      text: (widget.agent?.metadata?['max_tool_rounds'] ?? 100).toString(),
    );
    _taskTimeoutController = TextEditingController(
      text: (widget.agent?.metadata?['task_timeout_seconds'] ?? 600).toString(),
    );
  }

  /// 保存 Agent
  Future<void> _saveAgent() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      if (widget.agent == null) {
        // 新建模式
        final newAgent = Agent(
          id: '', // 服务器会生成
          name: _nameController.text.trim(),
          type: _typeController.text.trim(),
          avatar: _avatarController.text.trim().isEmpty
              ? '🤖'
              : _avatarController.text.trim(),
          metadata: {
            'max_tool_rounds': int.tryParse(_maxToolRoundsController.text.trim()) ?? 100,
            'task_timeout_seconds': int.tryParse(_taskTimeoutController.text.trim()) ?? 600,
          },
          provider: AgentProvider(name: 'Custom', platform: 'custom', type: 'custom'),
          status: AgentStatus(state: _selectedStatus),
        );

        await _apiService.registerAgent(newAgent);
        LoggerService().info('成功创建 Agent: ${newAgent.name}', tag: 'AgentDetail');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Agent 创建成功')),
          );
          Navigator.pop(context, true);
        }
      } else {
        // 编辑模式
        final updatedAgent = Agent(
          id: widget.agent!.id,
          name: _nameController.text.trim(),
          type: _typeController.text.trim(),
          avatar: _avatarController.text.trim().isEmpty
              ? '🤖'
              : _avatarController.text.trim(),
          metadata: {
            ...?widget.agent!.metadata,
            'max_tool_rounds': int.tryParse(_maxToolRoundsController.text.trim()) ?? 100,
            'task_timeout_seconds': int.tryParse(_taskTimeoutController.text.trim()) ?? 600,
          },
          provider: widget.agent!.provider,
          status: AgentStatus(state: _selectedStatus),
        );

        await _apiService.updateAgent(updatedAgent);
        LoggerService().info('成功更新 Agent: ${updatedAgent.name}', tag: 'AgentDetail');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Agent 更新成功')),
          );
          setState(() => _isEditing = false);
        }
      }
    } catch (e) {
      LoggerService().error('保存 Agent 失败', tag: 'AgentDetail', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ExceptionHandler.getUserMessage(e)),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNewAgent = widget.agent == null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isNewAgent
            ? '添加 Agent'
            : _isEditing
                ? '编辑 Agent'
                : 'Agent 详情'),
        centerTitle: true,
        actions: [
          if (!isNewAgent && !_isEditing)
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () => setState(() => _isEditing = true),
              tooltip: '编辑',
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Avatar 预览
                    Center(
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(30),
                        ),
                        alignment: Alignment.center,
                        child: _avatarController.text.isNotEmpty
                            ? AvatarImage(
                                avatar: _avatarController.text,
                                size: 120,
                                borderRadius: 30,
                                fallback: const Icon(Icons.smart_toy, size: 60),
                              )
                            : const Icon(Icons.smart_toy, size: 60),
                      ),
                    ),
                    const SizedBox(height: 32),

                    // Agent 名称
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Agent 名称',
                        hintText: '输入 Agent 名称',
                        prefixIcon: Icon(Icons.badge),
                        border: OutlineInputBorder(),
                      ),
                      enabled: _isEditing,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return '请输入 Agent 名称';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // Agent 类型
                    TextFormField(
                      controller: _typeController,
                      decoration: const InputDecoration(
                        labelText: 'Agent 类型',
                        hintText: '例如: assistant, chatbot',
                        prefixIcon: Icon(Icons.category),
                        border: OutlineInputBorder(),
                      ),
                      enabled: _isEditing,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return '请输入 Agent 类型';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // Agent 状态
                    DropdownButtonFormField<String>(
                      value: _selectedStatus,
                      decoration: const InputDecoration(
                        labelText: 'Agent 状态',
                        prefixIcon: Icon(Icons.circle),
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'online', child: Text('在线')),
                        DropdownMenuItem(value: 'offline', child: Text('离线')),
                        DropdownMenuItem(value: 'busy', child: Text('忙碌')),
                        DropdownMenuItem(value: 'error', child: Text('错误')),
                      ],
                      onChanged: _isEditing
                          ? (value) {
                              if (value != null) {
                                setState(() => _selectedStatus = value);
                              }
                            }
                          : null,
                    ),
                    const SizedBox(height: 16),

                    // Avatar URL
                    TextFormField(
                      controller: _avatarController,
                      decoration: const InputDecoration(
                        labelText: 'Avatar URL (可选)',
                        hintText: 'https://example.com/avatar.png',
                        prefixIcon: Icon(Icons.image),
                        border: OutlineInputBorder(),
                      ),
                      enabled: _isEditing,
                      onChanged: (value) => setState(() {}), // 触发预览更新
                    ),
                    const SizedBox(height: 16),

                    // 最大工具调用轮次
                    TextFormField(
                      controller: _maxToolRoundsController,
                      decoration: const InputDecoration(
                        labelText: '最大工具调用轮次',
                        hintText: '默认 100',
                        prefixIcon: Icon(Icons.repeat),
                        border: OutlineInputBorder(),
                        helperText: '单次对话中 LLM 最多可调用工具的轮数（1–500）',
                      ),
                      enabled: _isEditing,
                      keyboardType: TextInputType.number,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) return null;
                        final n = int.tryParse(value.trim());
                        if (n == null || n < 1 || n > 500) {
                          return '请输入 1 到 500 之间的整数';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // 任务超时时间
                    TextFormField(
                      controller: _taskTimeoutController,
                      decoration: const InputDecoration(
                        labelText: '任务超时时间（秒）',
                        hintText: '默认 600',
                        prefixIcon: Icon(Icons.timer),
                        border: OutlineInputBorder(),
                        helperText: '单次任务的最长等待时间（60–3600 秒）',
                      ),
                      enabled: _isEditing,
                      keyboardType: TextInputType.number,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) return null;
                        final n = int.tryParse(value.trim());
                        if (n == null || n < 60 || n > 3600) {
                          return '请输入 60 到 3600 之间的整数';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // Agent ID (只读，仅编辑模式显示)
                    if (!isNewAgent)
                      TextFormField(
                        initialValue: widget.agent!.id,
                        decoration: const InputDecoration(
                          labelText: 'Agent ID',
                          prefixIcon: Icon(Icons.fingerprint),
                          border: OutlineInputBorder(),
                        ),
                        enabled: false,
                      ),

                    const SizedBox(height: 32),

                    // 发起对话按钮（仅在查看模式下显示）
                    if (!isNewAgent && !_isEditing)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => _startConversation(widget.agent!),
                          icon: const Icon(Icons.chat),
                          label: const Text('发起对话'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),

                    if (!isNewAgent && !_isEditing)
                      const SizedBox(height: 16),

                    // 操作按钮
                    if (_isEditing)
                      Row(
                        children: [
                          if (!isNewAgent)
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () {
                                  setState(() {
                                    _isEditing = false;
                                    // 恢复原始值
                                    _nameController.text = widget.agent!.name;
                                    _typeController.text = widget.agent!.type ?? '';
                                    _avatarController.text =
                                        widget.agent!.avatar;
                                    _selectedStatus = widget.agent!.status.state;
                                    _maxToolRoundsController.text =
                                        (widget.agent!.metadata?['max_tool_rounds'] ?? 100).toString();
                                    _taskTimeoutController.text =
                                        (widget.agent!.metadata?['task_timeout_seconds'] ?? 600).toString();
                                  });
                                },
                                child: const Text('取消'),
                              ),
                            ),
                          if (!isNewAgent) const SizedBox(width: 16),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _saveAgent,
                              icon: const Icon(Icons.save),
                              label: Text(isNewAgent ? '创建' : '保存'),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  /// 发起与 Agent 的对话
  Future<void> _startConversation(Agent agent) async {
    setState(() => _isLoading = true);

    try {
      // 尝试查找已存在的 DM 频道
      final channels = await _apiService.getChannels();
      Channel? existingDM;

      for (final channel in channels) {
        if (channel.isDM &&
            channel.members.length == 1 &&
            channel.members[0].id == agent.id) {
          existingDM = channel;
          break;
        }
      }

      // 如果不存在，创建新的 DM 频道
      if (existingDM == null) {
        final dmChannel = Channel(
          id: '', // 服务器会生成
          name: agent.name,
          type: 'dm',
          members: [
            ChannelMember(
              id: agent.id,
              type: 'agent',
              role: 'member',
              joinedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          ],
          avatar: agent.avatar,
          description: '与 ${agent.name} 的对话',
        );

        existingDM = await _apiService.createChannel(dmChannel);
        LoggerService().info('创建了与 ${agent.name} 的 DM 频道: ${existingDM.id}', tag: 'AgentDetail');
      }

      setState(() => _isLoading = false);

      // 导航到聊天页面
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const ChatScreen(),
          ),
        );
      }
    } catch (e) {
      LoggerService().error('创建对话失败', tag: 'AgentDetail', error: e);
      setState(() => _isLoading = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('创建对话失败: ${ExceptionHandler.getUserMessage(e)}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _typeController.dispose();
    _avatarController.dispose();
    _maxToolRoundsController.dispose();
    _taskTimeoutController.dispose();
    _apiService.dispose();
    super.dispose();
  }
}
