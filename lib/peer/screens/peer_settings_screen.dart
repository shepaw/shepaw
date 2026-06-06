import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/paired_peer.dart';
import '../services/peer_connection_manager.dart';
import '../services/peer_storage_service.dart';
import '../services/peer_agent_host_service.dart';
import 'peer_chat_screen.dart';
import '../widgets/peer_device_icon.dart';
import '../../models/remote_agent.dart';
import '../../service_locator.dart' show getIt;
import '../../services/local_database_service.dart';
import '../../widgets/avatar_image.dart';

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

  /// 本机可分享的 agent（已开启「允许外部访问」），及其对该设备的分享开关状态。
  List<RemoteAgent> _shareableAgents = [];
  Map<String, bool> _shareDecisions = {};
  bool _shareLoading = true;

  @override
  void initState() {
    super.initState();
    _deviceName = widget.peer.deviceName;
    _isConnected = PeerConnectionManager.instance.getPeerState(widget.peer.id) ==
        PeerConnectionState.connected;
    _loadPeerAgents();
    _loadShareableAgents();
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

  /// 加载本机可分享的 agent（允许外部访问）及当前对该设备的分享决定。
  Future<void> _loadShareableAgents() async {
    try {
      final all = await getIt<LocalDatabaseService>().getAllRemoteAgents();
      final shareable = all
          .where((a) => a.isLocal && a.allowExternalAccess)
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final decisions = await PeerStorageService().getAgentShares(widget.peer.id);
      if (mounted) {
        setState(() {
          _shareableAgents = shareable;
          _shareDecisions = decisions;
          _shareLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _shareLoading = false);
    }
  }

  /// 切换某个本机 agent 是否分享给该设备，并把最新列表推送给对端。
  Future<void> _toggleShare(RemoteAgent agent, bool shared) async {
    setState(() => _shareDecisions[agent.id] = shared);
    await PeerStorageService().setAgentShare(widget.peer.id, agent.id, shared);
    // 设备在线时立即同步，使对端即时增删该 agent。
    if (PeerConnectionManager.instance.getPeerState(widget.peer.id) ==
        PeerConnectionState.connected) {
      await PeerAgentHostService.instance.pushAgentList(widget.peer.id);
    }
  }

  Future<void> _editName() async {
    final l10n = AppLocalizations.of(context);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController(text: _deviceName);
        return AlertDialog(
          title: Text(l10n.peerSettings_editAliasTitle),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: l10n.peerSettings_editAliasHint,
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.common_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(l10n.common_save),
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
    final l10n = AppLocalizations.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.peerSettings_deletePairing),
        content: Text(l10n.peerSettings_deleteConfirm(_deviceName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.common_delete),
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
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.peerSettings_title),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 24),

          // 设备头像 + 名称
          Center(
            child: Column(
              children: [
                PeerDeviceIcon(peer: widget.peer, size: 80, borderRadius: 20),
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
                      _isConnected ? l10n.peerSettings_online : l10n.peerSettings_offline,
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
          _buildSection(context, l10n.peerSettings_sectionBasic, [
            ListTile(
              leading: const Icon(Icons.edit),
              title: Text(l10n.peerSettings_aliasName),
              subtitle: Text(_deviceName),
              trailing: const Icon(Icons.chevron_right),
              onTap: _editName,
            ),
            ListTile(
              leading: const Icon(Icons.fingerprint),
              title: Text(l10n.peerSettings_fingerprint),
              subtitle: Text(_formatFingerprint(widget.peer.fingerprint)),
            ),
            ListTile(
              leading: const Icon(Icons.calendar_today),
              title: Text(l10n.peerSettings_pairedAt),
              subtitle: Text(_formatDate(widget.peer.pairedAt)),
            ),
            if (widget.peer.pairingRole != null)
              ListTile(
                leading: Icon(
                  widget.peer.pairingRole == PeerPairingRole.initiator
                      ? Icons.call_made
                      : Icons.call_received,
                ),
                title: Text(l10n.peerSettings_connectionInitiator),
                subtitle: Text(
                  '${widget.peer.pairingRoleShortLabel(l10n)} · ${widget.peer.pairingRoleDescription(l10n)}',
                ),
              ),
          ]),

          const SizedBox(height: 16),

          _buildShareSection(context),

          const SizedBox(height: 16),

          _buildAgentsSection(context),

          const SizedBox(height: 16),

          _buildSection(context, l10n.peerSettings_sectionConnection, [
            if (widget.peer.localEndpoint != null)
              ListTile(
                leading: const Icon(Icons.wifi),
                title: Text(l10n.peerSettings_localAddress),
                subtitle: Text(widget.peer.localEndpoint!),
              ),
            if (widget.peer.channelEndpoint != null)
              ListTile(
                leading: const Icon(Icons.cloud),
                title: Text(l10n.peerSettings_relayAddress),
                subtitle: Text(widget.peer.channelEndpoint!),
              ),
            ListTile(
              leading: const Icon(Icons.lock),
              title: Text(l10n.peerSettings_encryption),
              subtitle: Text(l10n.peerSettings_encryptionValue),
            ),
          ]),

          const SizedBox(height: 24),

          // 发起对话
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: _startChat,
              icon: const Icon(Icons.chat_bubble_outline),
              label: Text(l10n.peerSettings_startChat),
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
              label: Text(l10n.peerSettings_deletePairing, style: TextStyle(color: colorScheme.error)),
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

  /// 分享给该设备的本机 agent（仅列出已开启「允许外部访问」的 agent）。
  Widget _buildShareSection(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final List<Widget> children;
    if (_shareLoading) {
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
    } else if (_shareableAgents.isEmpty) {
      children = [
        ListTile(
          leading: Icon(Icons.ios_share, color: Colors.grey[400]),
          title: Text(
            l10n.peerSettings_noShareableAgents,
            style: TextStyle(color: Colors.grey[600]),
          ),
          subtitle: Text(
            l10n.peerSettings_enableExternalAccessHint,
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
        ),
      ];
    } else {
      children = _shareableAgents.map(_buildShareTile).toList();
    }

    final sharedCount =
        _shareableAgents.where((a) => _shareDecisions[a.id] == true).length;
    final shareTitle = _shareableAgents.isNotEmpty
        ? l10n.peerSettings_shareAgentsTitleCount(
            sharedCount,
            _shareableAgents.length,
          )
        : l10n.peerSettings_shareAgentsTitle;
    return _buildSection(context, shareTitle, children);
  }

  Widget _buildShareTile(RemoteAgent agent) {
    final shared = _shareDecisions[agent.id] == true;
    return SwitchListTile(
      secondary: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.indigo[50],
          borderRadius: BorderRadius.circular(10),
        ),
        clipBehavior: Clip.antiAlias,
        alignment: Alignment.center,
        child: _buildShareAgentAvatar(agent.avatar),
      ),
      title: Text(agent.name),
      subtitle: (agent.bio != null && agent.bio!.isNotEmpty)
          ? Text(agent.bio!, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      value: shared,
      onChanged: (v) => _toggleShare(agent, v),
    );
  }

  Widget _buildShareAgentAvatar(String avatar) {
    final isPath = (avatar.startsWith('/') && !avatar.startsWith('http')) ||
        avatar.startsWith('http') ||
        AvatarImage.isAsset(avatar);
    if (isPath) {
      return AvatarImage(
        avatar: avatar,
        size: 40,
        borderRadius: 10,
        fallback: const Icon(Icons.smart_toy_outlined),
      );
    }
    return Text(
      avatar.isNotEmpty ? avatar : '🤖',
      style: const TextStyle(fontSize: 20),
    );
  }

  /// 对方设备开放的、可被本机连接的 agent 列表。
  Widget _buildAgentsSection(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
            _isConnected
                ? l10n.peerSettings_noPeerAgentsConnected
                : l10n.peerSettings_noPeerAgentsOffline,
            style: TextStyle(color: Colors.grey[600]),
          ),
          subtitle: Text(
            _isConnected
                ? l10n.peerSettings_peerEnableExternalHint
                : l10n.peerSettings_syncAgentsOnConnect,
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
        ),
      ];
    } else {
      children = _peerAgents.map(_buildAgentTile).toList();
    }

    final agentsTitle = _peerAgents.isNotEmpty
        ? l10n.peerSettings_connectableAgentsTitleCount(_peerAgents.length)
        : l10n.peerSettings_connectableAgentsTitle;
    return _buildSection(context, agentsTitle, children);
  }

  Widget _buildAgentTile(RemoteAgent agent) {
    final l10n = AppLocalizations.of(context);
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
            online ? l10n.peerSettings_online : l10n.peerSettings_offline,
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
