import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/agent.dart';
import '../models/channel.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_settings_screen.dart';
import '../peer/screens/peer_pairing_screen.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/local_api_service.dart';
import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import '../widgets/avatar_image.dart';
import 'remote_agent_detail_screen.dart';
import 'group_detail_screen.dart';

/// Contacts management screen with Agents and Groups tabs.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final LocalApiService _apiService = LocalApiService();
  final LocalDatabaseService _databaseService = LocalDatabaseService();

  List<Agent> _agents = [];
  List<Channel> _groups = [];
  List<PairedPeer> _peers = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final agents = await _apiService.getAgents();
      final allChannels = await _databaseService.getAllChannels();
      final groups = allChannels
          .where((c) => c.isGroup && c.parentGroupId == null)
          .toList();

      List<PairedPeer> peers = [];
      try {
        await PeerConnectionManager.instance.start();
        peers = await PeerConnectionManager.instance.getAllPeers();
      } catch (_) {}

      if (mounted) {
        setState(() {
          _agents = agents;
          _groups = groups;
          _peers = peers;
          _isLoading = false;
        });
      }
    } catch (e) {
      LoggerService().error('Failed to load contacts data', tag: 'Contacts', error: e);
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.contacts_title),
        elevation: 1,
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: l10n.contacts_agents),
            Tab(text: l10n.contacts_groups),
            const Tab(text: '设备'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildAgentsList(),
                _buildGroupsList(),
                _buildPeersList(),
              ],
            ),
    );
  }

  Widget _buildAgentsList() {
    final l10n = AppLocalizations.of(context);

    if (_agents.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.smart_toy_outlined, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              l10n.contacts_noAgents,
              style: TextStyle(fontSize: 16, color: Colors.grey[400]),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        itemCount: _agents.length,
        itemBuilder: (context, index) => _buildAgentTile(_agents[index]),
      ),
    );
  }

  Widget _buildGroupsList() {
    final l10n = AppLocalizations.of(context);

    if (_groups.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.group_outlined, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              l10n.contacts_noGroups,
              style: TextStyle(fontSize: 16, color: Colors.grey[400]),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        itemCount: _groups.length,
        itemBuilder: (context, index) => _buildGroupTile(_groups[index]),
      ),
    );
  }

  Widget _buildAgentTile(Agent agent) {
    final l10n = AppLocalizations.of(context);
    final isOnline = agent.status.isOnline;

    return ListTile(
      leading: Stack(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: agent.avatar.length <= 2
                ? Text(agent.avatar, style: const TextStyle(fontSize: 20))
                : AvatarImage(
                    avatar: agent.avatar,
                    size: 48,
                    borderRadius: 12,
                    fallback: Text(
                      agent.name.isNotEmpty ? agent.name[0] : 'A',
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
          ),
          // Online status dot
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: isOnline ? Colors.green : Colors.grey,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ),
      title: Text(
        agent.name,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      subtitle: agent.bio != null && agent.bio!.isNotEmpty
          ? Text(
              agent.bio!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            )
          : Text(
              isOnline ? l10n.home_statusOnline : l10n.home_statusOffline,
              style: TextStyle(
                fontSize: 12,
                color: isOnline ? Colors.green : Colors.grey,
              ),
            ),
      trailing: const Icon(Icons.chevron_right, color: Colors.grey),
      onTap: () => _openAgentDetail(agent),
    );
  }

  Widget _buildGroupTile(Channel group) {
    final l10n = AppLocalizations.of(context);
    final memberCount = group.members.where((m) => m.id != 'user').length;

    return ListTile(
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Colors.blue[100],
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.group, size: 24, color: Colors.blue),
      ),
      title: Text(
        group.name,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        group.description?.isNotEmpty == true
            ? group.description!
            : l10n.contacts_memberCount(memberCount),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
      ),
      trailing: const Icon(Icons.chevron_right, color: Colors.grey),
      onTap: () => _openGroupDetail(group),
    );
  }

  Future<void> _openAgentDetail(Agent agent) async {
    // Load the RemoteAgent from database for the detail screen
    final remoteAgent = await _databaseService.getRemoteAgentById(agent.id);
    if (remoteAgent == null || !mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RemoteAgentDetailScreen(agent: remoteAgent),
      ),
    );
    // Reload on return in case of edits or deletion
    _loadData();
  }

  Future<void> _openGroupDetail(Channel group) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GroupDetailScreen(channel: group),
      ),
    );
    // Reload on return in case of deletion
    _loadData();
  }

  // ── 配对设备列表 ─────────────────────────────────────────────────────

  Widget _buildPeersList() {
    if (_peers.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.devices_other, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              '尚未配对任何设备',
              style: TextStyle(fontSize: 16, color: Colors.grey[400]),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _startPeerPairing,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('开始配对'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // 添加配对按钮
        Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _startPeerPairing,
              icon: const Icon(Icons.add),
              label: const Text('添加配对设备'),
            ),
          ),
        ),
        // 设备列表
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadData,
            child: ListView.builder(
              itemCount: _peers.length,
              itemBuilder: (context, index) => _buildPeerTile(_peers[index]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPeerTile(PairedPeer peer) {
    final isConnected = peer.state == PeerConnectionState.connected;

    return ListTile(
      leading: Stack(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.teal[100],
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.smartphone, size: 24, color: Colors.teal),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: isConnected ? Colors.green : Colors.grey,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ),
      title: Text(
        peer.deviceName,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        isConnected ? '已连接 (端到端加密)' : '未连接',
        style: TextStyle(
          fontSize: 12,
          color: isConnected ? Colors.green : Colors.grey,
        ),
      ),
      trailing: const Icon(Icons.chevron_right, color: Colors.grey),
      onTap: () => _openPeerDetail(peer),
      onLongPress: () => _showPeerActions(peer),
    );
  }

  Future<void> _showPeerActions(PairedPeer peer) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('修改备注'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
              title: Text('删除配对', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );

    if (!mounted) return;
    if (action == 'rename') {
      await _renamePeer(peer);
    } else if (action == 'delete') {
      await _deletePeer(peer);
    }
  }

  Future<void> _renamePeer(PairedPeer peer) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController(text: peer.deviceName);
        return AlertDialog(
          title: const Text('修改备注'),
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

    if (newName != null && newName.isNotEmpty && newName != peer.deviceName) {
      await PeerStorageService().updateDeviceName(peer.id, newName);
      _loadData();
    }
  }

  Future<void> _deletePeer(PairedPeer peer) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除配对'),
        content: Text('确定要删除与 ${peer.deviceName} 的配对吗？\n所有消息记录也会被删除。'),
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
      await PeerConnectionManager.instance.removePeer(peer.id);
      _loadData();
    }
  }

  Future<void> _startPeerPairing() async {
    final peer = await PeerPairingScreen.show(context);
    if (peer != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已与 ${peer.deviceName} 配对成功')),
      );
      _loadData();
    }
  }

  Future<void> _openPeerDetail(PairedPeer peer) async {
    await PeerSettingsScreen.show(context, peer);
    // 详情页可能改了备注或删除了配对，返回后刷新列表。
    if (mounted) _loadData();
  }
}
