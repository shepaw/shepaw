import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../services/local_api_service.dart';
import '../services/logger_service.dart';
import '../utils/exceptions.dart';
import '../l10n/app_localizations.dart';

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
    final l10n = AppLocalizations.of(context);
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
      LoggerService().error(l10n.channel_loadFailed, tag: 'ChannelList', error: e);
      setState(() {
        _errorMessage = ExceptionHandler.getUserMessage(e);
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.channel_management),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadChannels,
            tooltip: l10n.common_refresh,
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateChannelDialog(),
        icon: const Icon(Icons.add),
        label: Text(l10n.channel_create),
      ),
    );
  }

  Widget _buildBody() {
    final l10n = AppLocalizations.of(context);
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
              label: Text(l10n.common_retry),
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
              l10n.channel_empty,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.channel_emptyHint,
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
    final l10n = AppLocalizations.of(context);
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
                PopupMenuItem(
                  value: 'bridge',
                  child: Row(
                    children: [
                      Icon(Icons.link, size: 20),
                      SizedBox(width: 8),
                      Text(l10n.channel_knotBridge),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'open',
                  child: Row(
                    children: [
                      Icon(Icons.open_in_new, size: 20),
                      SizedBox(width: 8),
                      Text(l10n.channel_open),
                    ],
                  ),
                ),
              ],
              onSelected: (value) {
                if (value == 'bridge') {
                  _openBridgeManagement(channel);
                } else if (value == 'open') {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.channel_opening(channel.name))),
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
                    label: Text(l10n.channel_knotBridge),
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
                        SnackBar(content: Text(l10n.channel_opening(channel.name))),
                      );
                    },
                    icon: const Icon(Icons.chat, size: 18),
                    label: Text(l10n.common_enter),
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
    final l10n = AppLocalizations.of(context);    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.channel_knotRemoved),
      ),
    );
  }

  /// 显示创建频道对话框
  void _showCreateChannelDialog() {
    final l10n = AppLocalizations.of(context);
    final nameController = TextEditingController();
    final descController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.channel_create),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: l10n.channel_name,
                hintText: l10n.channel_nameHint,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descController,
              decoration: InputDecoration(
                labelText: l10n.channel_descOptional,
                hintText: l10n.channel_descHint,
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.common_cancel),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.channel_nameRequired)),
                );
                return;
              }

              Navigator.pop(context);
              await _createChannel(name, descController.text.trim());
            },
            child: Text(l10n.createGroup_create),
          ),
        ],
      ),
    );
  }

  /// 创建频道
  Future<void> _createChannel(String name, String description) async {
    final l10n = AppLocalizations.of(context);    try {
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
          SnackBar(content: Text(l10n.channel_createdSuccess(name))),
        );
        _loadChannels();
      }
    } catch (e) {
      LoggerService().error(l10n.channel_createFailed, tag: 'ChannelList', error: e);
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
