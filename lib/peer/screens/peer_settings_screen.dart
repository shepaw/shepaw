import 'dart:async';

import 'package:flutter/material.dart';

import '../../config/product_features.dart';
import '../../l10n/app_localizations.dart';
import '../../service_locator.dart' show getIt;
import '../../services/contacts_directory.dart';
import '../../services/logger_service.dart';
import '../../screens/storage_browser_screen.dart';
import '../../storage/store_protocol.dart' show TrustLevel;
import '../../storage/store_service.dart';
import '../../widgets/form_bottom_bar.dart';
import '../models/paired_peer.dart';
import '../peer_device_actions.dart';
import '../services/peer_connection_manager.dart';
import '../services/peer_storage_service.dart';
import '../widgets/peer_agent_manage_panel.dart';
import '../widgets/peer_store_share_panel.dart';
import 'peer_chat_screen.dart';
import 'engine_management_screen.dart';
import '../widgets/peer_device_icon.dart';

/// P2P 设备设置页面
///
/// 可修改备注名称、查看设备信息、删除配对等。
class PeerSettingsScreen extends StatefulWidget {
  final PairedPeer peer;

  /// 通讯录里那一行的快照。
  ///
  /// 主机名单里的设备用的是主机侧的 id，本机 `paired_peers` 表里没有它：
  /// 在线状态、Agent 归属都只能靠通讯录算好的结果，不能拿 peer.id 去查本机。
  /// 从会话页进来时没有这一行，退回按 peer 自己判断。
  final ContactDevice? device;

  /// 嵌在桌面右栏时没有可弹出的路由。删除成功后由外层收起面板。
  final VoidCallback? onDeleted;

  const PeerSettingsScreen({
    super.key,
    required this.peer,
    this.device,
    this.onDeleted,
  });

  /// 返回 true 表示 peer 被删除了
  static Future<bool?> show(
    BuildContext context,
    PairedPeer peer, {
    ContactDevice? device,
  }) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PeerSettingsScreen(peer: peer, device: device),
      ),
    );
  }

  @override
  State<PeerSettingsScreen> createState() => _PeerSettingsScreenState();
}

class _PeerSettingsScreenState extends State<PeerSettingsScreen> {
  /// 通讯录里这一行的快照。没有显式传入时按指纹从最新快照里找一行。
  late ContactDevice? _device;
  late String _deviceName;
  late bool _isConnected;
  late String _trustLevel;
  bool _isMaster = false;
  StreamSubscription<void>? _peerListSub;
  StreamSubscription<ContactsView>? _directorySub;

  @override
  void initState() {
    super.initState();
    _device = widget.device ?? _lookupDevice();
    _deviceName = widget.peer.deviceName;
    _trustLevel = widget.peer.trustLevel;
    _isConnected = _onlineFrom(_device);
    _peerListSub = PeerConnectionManager.instance.peerListChanged.listen((_) {
      _refreshConnectionState();
    });
    // 桌面右栏是按 peer.id 建 key 挂载的，列表里改名后右栏不会重建，
    // 只能靠通讯录的快照自己跟上。
    if (getIt.isRegistered<ContactsDirectory>()) {
      _directorySub = getIt<ContactsDirectory>().snapshots.listen((view) {
        if (!mounted) return;
        final fresh = _device == null
            ? null
            : view.devices
                .where((item) => item.rowKey == _device!.rowKey)
                .firstOrNull;
        if (fresh == null) return;
        setState(() {
          _device = fresh;
          _deviceName = fresh.peer.deviceName;
          _isConnected = _onlineFrom(fresh);
        });
      });
    }
    _loadMaster();
  }

  /// 从会话页、桌面右栏进来时拿不到通讯录那一行，按指纹自己找。
  ContactDevice? _lookupDevice() {
    if (!getIt.isRegistered<ContactsDirectory>()) return null;
    final fingerprint = widget.peer.fingerprint.trim().toLowerCase();
    if (fingerprint.isEmpty) return null;
    return getIt<ContactsDirectory>()
        .latest
        ?.devices
        .where((item) =>
            item.peer.fingerprint.trim().toLowerCase() == fingerprint)
        .firstOrNull;
  }

  /// 名单还没同步回来、由 Agent 名单补出来的节点行。它没有真正的配对记录，
  /// 配对时间、发起方、删除配对这些都不成立。
  bool get _isUnlistedNode =>
      _device != null && _device!.peer.id.startsWith('node:');

  /// 管理 / 查询请求要发往的主机。名单设备的 id 是主机侧的，直接发没人认。
  String get _hostPeerId {
    if (_device == null) return widget.peer.id;
    final host = getIt.isRegistered<ContactsDirectory>()
        ? getIt<ContactsDirectory>().latest?.host?.id
        : null;
    return host ?? widget.peer.id;
  }

  /// 名单设备的在线状态由通讯录算好；本机配对过的才能查连接管理器。
  bool _onlineFrom(ContactDevice? device) {
    if (device != null) return device.online;
    return PeerConnectionManager.instance.getPeerState(widget.peer.id) ==
        PeerConnectionState.connected;
  }

  Future<void> _loadMaster() async {
    final master = await StoreService.instance.masterDeviceId();
    if (!mounted) return;
    setState(() => _isMaster = master == widget.peer.fingerprint);
  }

  @override
  void dispose() {
    _peerListSub?.cancel();
    _directorySub?.cancel();
    super.dispose();
  }

  void _refreshConnectionState() {
    // 名单设备的在线状态只有通讯录知道，连接管理器里查不到它的 id。
    if (_device != null) return;
    final connected = PeerConnectionManager.instance.getPeerState(widget.peer.id) ==
        PeerConnectionState.connected;
    if (mounted && connected != _isConnected) {
      setState(() => _isConnected = connected);
    }
  }

  Future<void> _editName() async {
    final newName = await PeerDeviceActions.rename(context, widget.peer);
    if (newName == null || !mounted) return;
    setState(() => _deviceName = newName);
  }

  void _startChat() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PeerChatScreen(peer: widget.peer),
      ),
    );
  }

  void _browsePeerStorage() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => StorageBrowserScreen(
          deviceId: widget.peer.fingerprint,
          deviceName: _deviceName,
          readOnly: true,
          peerId: widget.peer.id,
        ),
      ),
    );
  }

  Future<void> _openEngineManagement() {
    return EngineManagementScreen.show(context, peerId: widget.peer.id);
  }

  Future<void> _changeTrustLevel() async {
    final l10n = AppLocalizations.of(context);
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.peerSettings_trustLevel),
        children: [
          RadioListTile<String>(
            title: Text(l10n.peerPairing_trustOwner),
            value: TrustLevel.owner,
            groupValue: _trustLevel,
            onChanged: (v) => Navigator.pop(ctx, v),
          ),
          RadioListTile<String>(
            title: Text(l10n.peerPairing_trustFriend),
            value: TrustLevel.friend,
            groupValue: _trustLevel,
            onChanged: (v) => Navigator.pop(ctx, v),
          ),
        ],
      ),
    );
    if (selected == null || selected == _trustLevel || !mounted) return;

    try {
      if (selected == TrustLevel.owner && _trustLevel == TrustLevel.friend) {
        final apply = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.peerSettings_trustLevel),
            content: Text(l10n.peerSettings_trustOwnerHint),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.peerSettings_keepShares),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.peerSettings_applyOwnerDefaults),
              ),
            ],
          ),
        );
        // 点空白处关掉是「取消」：升级成所有者会放宽一台设备的权限，
        // 不能在用户没有明确选择时默默做掉。
        if (apply == null || !mounted) return;
        await PeerStorageService().setTrustLevel(widget.peer.id, selected);
        if (apply) {
          await StoreService.instance.setOutboundStoreShares(
            widget.peer.id,
            PeerStorageService.ownerDefaultStoreShares(),
          );
        }
      } else if (selected == TrustLevel.friend) {
        await PeerStorageService().setTrustLevel(widget.peer.id, selected);
        // 保存成功后才提示；先弹再存的话，失败时用户会同时看到两个相反的提示。
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.peerSettings_trustFriendHint)),
          );
        }
      } else {
        await PeerStorageService().setTrustLevel(widget.peer.id, selected);
      }

      if (mounted) setState(() => _trustLevel = selected);
      PeerConnectionManager.instance.notifyPeerListChanged();
    } catch (e) {
      LoggerService().error(
        'change trust level failed',
        tag: 'PeerSettings',
        error: e,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.peerSettings_trustUpdateFailed)),
      );
    }
  }

  void _openStoreSharePanel() {
    final l10n = AppLocalizations.of(context);
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(l10n.peerStoreShare_panelTitle)),
          body: PeerStoreSharePanel(peerId: widget.peer.id),
        ),
      ),
    );
  }

  Future<void> _deletePeer() async {
    final confirm = await PeerDeviceActions.confirmDelete(
      context,
      widget.peer,
      isHost: _device?.isHost ?? widget.peer.isHost,
      isThisDevice: _device?.isThisDevice ?? false,
    );
    if (!confirm || !mounted) return;

    final removed = await PeerDeviceActions.delete(context, widget.peer);
    if (!removed || !mounted) return;
    final onDeleted = widget.onDeleted;
    if (onDeleted != null) {
      onDeleted();
    } else {
      Navigator.of(context).pop(true);
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
      body: Column(
        children: [
          Expanded(
            child: ListView(
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
                    if (_isMaster) ...[
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          l10n.storage_masterBadge,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
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
            if (_isMaster)
              ListTile(
                leading: const Icon(Icons.star_outline),
                title: Text(l10n.storage_masterNode),
                subtitle: Text(l10n.storage_nasPaired),
              ),
            ListTile(
              leading: const Icon(Icons.fingerprint),
              title: Text(l10n.peerSettings_fingerprint),
              subtitle: Text(_formatFingerprint(widget.peer.fingerprint)),
            ),
            if (!_isUnlistedNode)
              ListTile(
                leading: const Icon(Icons.calendar_today),
                title: Text(l10n.peerSettings_pairedAt),
                subtitle: Text(_formatDate(widget.peer.pairedAt)),
              ),
            if (widget.peer.pairingRole != null && !_isUnlistedNode)
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

          _buildSection(context, l10n.storage_spaceSection, [
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(l10n.storage_peerSpaceEntry),
              subtitle: Text(l10n.storage_sharedBrowseHint),
              trailing: const Icon(Icons.chevron_right),
              onTap: _browsePeerStorage,
            ),
            ListTile(
              leading: const Icon(Icons.folder_shared_outlined),
              title: Text(l10n.peerStoreShare_panelTitle),
              subtitle: Text(l10n.peerStoreShare_panelHint),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openStoreSharePanel,
            ),
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: Text(l10n.peerSettings_trustLevel),
              subtitle: Text(_trustLevel == TrustLevel.friend
                  ? l10n.peerPairing_trustFriend
                  : l10n.peerPairing_trustOwner),
              trailing: const Icon(Icons.chevron_right),
              onTap: _changeTrustLevel,
            ),
          ]),

          const SizedBox(height: 16),

          PeerAgentManagePanel(
            // 管理请求走主机：名单里的工作节点用的是主机侧 id，直接发过去没人认。
            peerId: _hostPeerId,
            isPeerConnected: _isConnected,
            nodeId: _device?.nodeId,
            agentIds: _device?.agents.map((a) => a.id).toSet(),
          ),

          const SizedBox(height: 16),

          _buildSection(context, l10n.peerSettings_engineLabel, [
            ListTile(
              leading: const Icon(Icons.memory),
              title: Text(l10n.engineManagement_title),
              subtitle: Text(l10n.engineManagement_entryHint),
              trailing: const Icon(Icons.chevron_right),
              enabled: _isConnected,
              onTap: _isConnected ? () => unawaited(_openEngineManagement()) : null,
            ),
          ]),

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

          // 危险操作。名单还没同步回来的节点行没有真正的配对记录，删了没意义。
          if (!_isUnlistedNode)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton.icon(
                onPressed: _deletePeer,
                icon: Icon(Icons.delete_forever, color: colorScheme.error),
                label: Text(l10n.peerSettings_deletePairing, style: TextStyle(color: colorScheme.error)),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: colorScheme.error),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),

          const SizedBox(height: 16),
              ],
            ),
          ),
          if (ProductFeatures.deviceChatUiEnabled)
            FormBottomBar(
              child: FormPrimaryButton(
                onPressed: _startChat,
                icon: Icons.chat_bubble_outline,
                label: l10n.peerSettings_startChat,
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
