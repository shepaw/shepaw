import 'dart:async';

import 'package:flutter/material.dart';

import '../models/paired_peer.dart';
import '../services/peer_connection_manager.dart';
import '../services/peer_storage_service.dart';
import 'peer_chat_screen.dart';
import '../../models/remote_agent.dart';
import '../../service_locator.dart' show getIt;
import '../../services/local_database_service.dart';

/// P2P 设备设置页面
///
/// 可修改备注名称、查看设备信息、删除配对等。
class PeerSettingsScreen extends StatefulWidget {
  final PairedPeer peer;

  const PeerSettingsScreen({super.key, required this.peer});

  /// 返回 true 表示 peer 被删除了
  static Future<bool?> show(BuildContext context, PairedPeer peer) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => PeerSettingsScreen(peer: peer)),
    );
  }

  @override
  State<PeerSettingsScreen> createState() => _PeerSettingsScreenState();
}

class _PeerSettingsScreenState extends State<PeerSettingsScreen> {
  late String _deviceName;
  late bool _isConnected;

  /// 对方开放、本机可连接的 agent 列表。
  List<RemoteAgent> _peerAgents = [];
  bool _agentsLoading = true;
  StreamSubscription<void>? _peerListSub;

  @override
  void initState() {
    super.initState();
    _deviceName = widget.peer.deviceName;
    _isConnected = PeerConnectionManager.instance.getPeerState(widget.peer.id) ==
        PeerConnectionState.connected;
    _loadPeerAgents();
    // agent 列表在对端连接/上报后会刷新，这里跟随刷新。
    _peerListSub = PeerConnectionManager.instance.peerListChanged.listen((_) {
      _refreshConnectionState();
      _loadPeerAgents();
    });
  }

  @override
  void dispose() {
    _peerListSub?.cancel();
    super.dispose();
  }

  void _refreshConnectionState() {
    final connected = PeerConnectionManager.instance.getPeerState(widget.peer.id) ==
        PeerConnectionState.connected;
    if (mounted && connected != _isConnected) {
      setState(() => _isConnected = connected);
    }
  }

  Future<void> _loadPeerAgents() async {
    try {
      final all = await getIt<LocalDatabaseService>().getAllRemoteAgents();
      final mine = all
          .where((a) =>
              a.protocol == ProtocolType.peer &&
              a.sourcePeerId == widget.peer.id)
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (mounted) {
        setState(() {
          _peerAgents = mine;
          _agentsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _agentsLoading = false);
    }
  }

  Future<void> _editName() async {
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController(text: _deviceName);
        return AlertDialog(
          title: const Text('修改备注名称'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '输入备注名称',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (newName != null && newName.isNotEmpty && newName != _deviceName) {
      await PeerStorageService().updateDeviceName(widget.peer.id, newName);
      if (mounted) {
        setState(() => _deviceName = newName);
      }
    }
  }

  void _startChat() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PeerChatScreen(peer: widget.peer),
      ),
    );
  }

  Future<void> _deletePeer() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除配对'),
        content: Text('确定要删除与 $_deviceName 的配对吗？\n所有消息记录也会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await PeerConnectionManager.instance.removePeer(widget.peer.id);
      if (mounted) {
        Navigator.of(context).pop(true); // 返回 true 表示已删除
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('设备设置'),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 24),

          // 设备头像 + 名称
          Center(
            child: Column(
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: Colors.teal[50],
                    borderRadius: BorderRadius.circular(20),
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.smartphone, size: 40, color: Colors.teal[600]),
                ),
                const SizedBox(height: 12),
                Text(
                  _deviceName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.circle,
                      size: 10,
                      color: _isConnected ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _isConnected ? '在线' : '离线',
                      style: TextStyle(
                        color: _isConnected ? Colors.green : Colors.grey,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // 设置项
          _buildSection(context, '基本信息', [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('备注名称'),
              subtitle: Text(_deviceName),
              trailing: const Icon(Icons.chevron_right),
              onTap: _editName,
            ),
            ListTile(
              leading: const Icon(Icons.fingerprint),
              title: const Text('设备指纹'),
              subtitle: Text(_formatFingerprint(widget.peer.fingerprint)),
            ),
            ListTile(
              leading: const Icon(Icons.calendar_today),
              title: const Text('配对时间'),
              subtitle: Text(_formatDate(widget.peer.pairedAt)),
            ),
            if (widget.peer.pairingRole != null)
              ListTile(
                leading: Icon(
                  widget.peer.pairingRole == PeerPairingRole.initiator
                      ? Icons.call_made
                      : Icons.call_received,
                ),
                title: const Text('连接发起方'),
                subtitle: Text(
                  '${widget.peer.pairingRoleShortLabel} · ${widget.peer.pairingRoleDescription}',
                ),
              ),
          ]),

          const SizedBox(height: 16),

          _buildAgentsSection(context),

          const SizedBox(height: 16),

          _buildSection(context, '连接信息', [
            if (widget.peer.localEndpoint != null)
              ListTile(
                leading: const Icon(Icons.wifi),
                title: const Text('内网地址'),
                subtitle: Text(widget.peer.localEndpoint!),
              ),
            if (widget.peer.channelEndpoint != null)
              ListTile(
                leading: const Icon(Icons.cloud),
                title: const Text('外网中继'),
                subtitle: Text(widget.peer.channelEndpoint!),
              ),
            ListTile(
              leading: const Icon(Icons.lock),
              title: const Text('加密方式'),
              subtitle: const Text('Noise IK (X25519 + ChaCha20-Poly1305)'),
            ),
          ]),

          const SizedBox(height: 24),

          // 发起对话
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: _startChat,
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('发起对话'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
              ),
            ),
          ),

          const SizedBox(height: 12),

          // 危险操作
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: _deletePeer,
              icon: Icon(Icons.delete_forever, color: colorScheme.error),
              label: Text('删除配对', style: TextStyle(color: colorScheme.error)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: colorScheme.error),
                minimumSize: const Size(double.infinity, 48),
              ),
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  /// 对方设备开放的、可被本机连接的 agent 列表。
  Widget _buildAgentsSection(BuildContext context) {
    final List<Widget> children;
    if (_agentsLoading) {
      children = const [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ];
    } else if (_peerAgents.isEmpty) {
      children = [
        ListTile(
          leading: Icon(Icons.smart_toy_outlined, color: Colors.grey[400]),
          title: Text(
            _isConnected ? '该设备暂未开放任何 Agent' : '设备离线，暂无可连接的 Agent',
            style: TextStyle(color: Colors.grey[600]),
          ),
          subtitle: Text(
            _isConnected ? '对方可在 Agent 设置中开启「允许外部访问」' : '连接后将自动同步可连接的 Agent',
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
        ),
      ];
    } else {
      children = _peerAgents.map(_buildAgentTile).toList();
    }

    return _buildSection(
      context,
      '可连接的 Agent${_peerAgents.isNotEmpty ? ' (${_peerAgents.length})' : ''}',
      children,
    );
  }

  Widget _buildAgentTile(RemoteAgent agent) {
    final online = agent.status == AgentStatus.online;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.indigo[50],
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(
          agent.avatar.isNotEmpty ? agent.avatar : '🤖',
          style: const TextStyle(fontSize: 20),
        ),
      ),
      title: Text(agent.name),
      subtitle: (agent.bio != null && agent.bio!.isNotEmpty)
          ? Text(agent.bio!, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: online ? Colors.green : Colors.grey),
          const SizedBox(width: 4),
          Text(
            online ? '在线' : '离线',
            style: TextStyle(
              fontSize: 12,
              color: online ? Colors.green : Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(BuildContext context, String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Colors.grey[600],
            ),
          ),
        ),
        ...children,
      ],
    );
  }

  String _formatFingerprint(String fp) {
    final buffer = StringBuffer();
    for (var i = 0; i < fp.length; i++) {
      if (i > 0 && i % 4 == 0) buffer.write(' ');
      buffer.write(fp[i]);
    }
    return buffer.toString();
  }

  String _formatDate(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
