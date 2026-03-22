import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../services/local_api_service.dart';
import '../services/logger_service.dart';
import '../utils/exceptions.dart';

/// 频道列表页面
class ChannelListScreen extends StatefulWidget {
  const ChannelListScreen({Key? key}) : super(key: key);

  @override
  State<ChannelListScreen> createState() => _ChannelListScreenState();
}

class _ChannelListScreenState extends State<ChannelListScreen> {
  final LocalApiService _apiService = LocalApiService();
  List<Channel> _channels = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  /// 加载频道列表
  Future<void> _loadChannels() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final channels = await _apiService.getChannels();
      setState(() {
        _channels = channels;
        _isLoading = false;
      });
      LoggerService().info('加载了 ${channels.length} 个频道', tag: 'ChannelList');
    } catch (e) {
      LoggerService().error('加载频道列表失败', tag: 'ChannelList', error: e);
      setState(() {
        _errorMessage = ExceptionHandler.getUserMessage(e);
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('频道管理'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadChannels,
            tooltip: '刷新',
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateChannelDialog(),
        icon: const Icon(Icons.add),
        label: const Text('创建频道'),
      ),
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
            Icon(
              Icons.error_outline,
              size: 64,
              color: Colors.red[300],
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: TextStyle(color: Colors.red[700]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _loadChannels,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_channels.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.forum_outlined,
              size: 100,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 24),
            Text(
              '暂无频道',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '点击下方按钮创建您的第一个频道',
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadChannels,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _channels.length,
        itemBuilder: (context, index) {
          final channel = _channels[index];
          return _buildChannelCard(channel);
        },
      ),
    );
  }

  Widget _buildChannelCard(Channel channel) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.purple.withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.forum,
                color: Colors.purple,
              ),
            ),
            title: Text(
              channel.name,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ID: ${channel.id}'),
                if (channel.description != null &&
                    channel.description!.isNotEmpty)
                  Text(
                    channel.description!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
            trailing: PopupMenuButton(
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'bridge',
                  child: Row(
                    children: [
                      Icon(Icons.link, size: 20),
                      SizedBox(width: 8),
                      Text('Knot 桥接'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'open',
                  child: Row(
                    children: [
                      Icon(Icons.open_in_new, size: 20),
                      SizedBox(width: 8),
                      Text('打开频道'),
                    ],
                  ),
                ),
              ],
              onSelected: (value) {
                if (value == 'bridge') {
                  _openBridgeManagement(channel);
                } else if (value == 'open') {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('打开频道: ${channel.name}')),
                  );
                }
              },
            ),
            onTap: () => _openBridgeManagement(channel),
          ),
          // 添加快捷操作按钮
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _openBridgeManagement(channel),
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('Knot 桥接'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.teal,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('打开频道: ${channel.name}')),
                      );
                    },
                    icon: const Icon(Icons.chat, size: 18),
                    label: const Text('进入'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 打开桥接管理页面（已移除 Knot 功能）
  void _openBridgeManagement(Channel channel) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Knot 桥接功能已移除，请使用远端助手功能'),
      ),
    );
  }

  /// 显示创建频道对话框
  void _showCreateChannelDialog() {
    final nameController = TextEditingController();
    final descController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('创建频道'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '频道名称',
                hintText: '输入频道名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descController,
              decoration: const InputDecoration(
                labelText: '频道描述（可选）',
                hintText: '输入频道描述',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入频道名称')),
                );
                return;
              }

              Navigator.pop(context);
              await _createChannel(name, descController.text.trim());
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  /// 创建频道
  Future<void> _createChannel(String name, String description) async {
    try {
      final channel = Channel.withMemberIds(
        id: '',
        name: name,
        type: 'group',
        memberIds: [],
        description: description.isEmpty ? null : description,
      );

      await _apiService.createChannel(channel);
      LoggerService().info('成功创建频道: $name', tag: 'ChannelList');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('频道 "$name" 创建成功')),
        );
        _loadChannels();
      }
    } catch (e) {
      LoggerService().error('创建频道失败', tag: 'ChannelList', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ExceptionHandler.getUserMessage(e)),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _apiService.dispose();
    super.dispose();
  }
}
