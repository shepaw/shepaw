import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/remote_agent.dart';
import '../../service_locator.dart' show getIt;
import '../../services/chat_navigation_service.dart';
import '../../services/local_database_service.dart';
import '../../services/remote_agent_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/agent_list_avatar.dart';
import '../services/peer_agent_client_service.dart';
import '../services/peer_connection_manager.dart';
import '../screens/add_agent_instance_screen.dart';

/// Device-details section: list peer agents, toggle whether they appear in
/// this app, and create or remove agents on the device.
class PeerAgentManagePanel extends StatefulWidget {
  /// 管理请求发给谁。主机名单里的设备用的是主机侧的 id，请求仍然走主机。
  final String peerId;

  /// 只看这个工作节点上的 Agent。主机为 null。
  final String? nodeId;

  /// 通讯录算好的归属名单（按 Agent id）。
  ///
  /// 工作节点上的 Agent 在库里记的 `source_peer_id` 是主机，只能靠元数据里
  /// 的 `node_id` 二次区分；不传就只能自己按 source_peer_id 猜，节点下会是空的。
  final Set<String>? agentIds;

  final bool isPeerConnected;

  /// 桌面右栏里由外层铺「新建 Agent」面板，避免在嵌套 Navigator 里再叠一页。
  final ValueChanged<String?>? onAddAgent;

  const PeerAgentManagePanel({
    super.key,
    required this.peerId,
    required this.isPeerConnected,
    this.nodeId,
    this.agentIds,
    this.onAddAgent,
  });

  @override
  State<PeerAgentManagePanel> createState() => _PeerAgentManagePanelState();
}

class _PeerAgentManagePanelState extends State<PeerAgentManagePanel> {
  List<PeerAgentManageEntry> _entries = const [];
  List<RemoteAgent> _localAgents = const [];
  bool _loading = true;
  bool _showHidden = false;
  String? _error;
  String? _busyId;
  StreamSubscription<void>? _peerListSub;

  @override
  void initState() {
    super.initState();
    _load();
    _peerListSub = PeerConnectionManager.instance.peerListChanged.listen((_) {
      _load(quiet: true);
    });
  }

  @override
  void didUpdateWidget(covariant PeerAgentManagePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPeerConnected != widget.isPeerConnected ||
        oldWidget.nodeId != widget.nodeId) {
      // 连接状态一变就整块转圈会把已经显示出来的 Agent 清掉；静默重取即可。
      _load(quiet: true);
    }
  }

  @override
  void dispose() {
    _peerListSub?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet && mounted) setState(() => _loading = true);
    final all = await getIt<LocalDatabaseService>().getAllRemoteAgents();
    final scoped = widget.agentIds;
    final mine = all.where((a) {
      if (a.protocol != ProtocolType.peer) return false;
      if (scoped == null) return a.sourcePeerId == widget.peerId;
      final id = a.remoteAgentId ?? a.id;
      return scoped.contains(id) || scoped.contains(a.id);
    }).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    PeerAgentManageResult? remote;
    if (widget.isPeerConnected) {
      remote = await PeerAgentClientService.instance.manageAgents(
        peerId: widget.peerId,
        op: 'list',
        nodeId: widget.nodeId,
      );
    }

    if (!mounted) return;
    setState(() {
      _localAgents = mine;
      _loading = false;
      if (remote == null) {
        _error = null;
        _entries = mine.map(_entryFromLocal).toList();
        return;
      }
      _error = remote.ok || remote.unsupported ? null : remote.error;
      if (remote.agents.isNotEmpty) {
        _entries = remote.agents;
      } else if (remote.ok || remote.unsupported) {
        _entries = mine.map(_entryFromLocal).toList();
      }
    });
  }

  PeerAgentManageEntry _entryFromLocal(RemoteAgent a) {
    return PeerAgentManageEntry(
      id: a.remoteAgentId ?? a.id,
      name: a.name,
      engine: (a.metadata['engine'] as String?) ?? '',
      running: a.peerAgentRunning,
      enabled: a.peerAgentEnabled,
      manageable: a.peerAgentManageable,
    );
  }

  RemoteAgent? _localFor(PeerAgentManageEntry entry) {
    return _localAgents.cast<RemoteAgent?>().firstWhere(
          (a) => a!.remoteAgentId == entry.id || a.id == entry.id,
          orElse: () => null,
        );
  }

  Future<void> _setVisibleOnApp(RemoteAgent local, bool visible) async {
    setState(() => _busyId = local.remoteAgentId ?? local.id);
    try {
      final latest =
          await getIt<LocalDatabaseService>().getRemoteAgentById(local.id) ??
              local;
      final metadata = Map<String, dynamic>.from(latest.metadata);
      if (visible) {
        metadata.remove('hidden_on_this_app');
      } else {
        metadata['hidden_on_this_app'] = true;
      }
      await getIt<RemoteAgentService>().updateAgent(
        latest.copyWith(metadata: metadata),
      );
      PeerConnectionManager.instance.notifyPeerListChanged();
      await _load(quiet: true);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _createAgent() async {
    final onAdd = widget.onAddAgent;
    if (onAdd != null) {
      onAdd(widget.nodeId);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AddAgentInstanceScreen(
          presetPeerId: widget.peerId,
          presetNodeId: widget.nodeId,
        ),
      ),
    );
    if (!mounted) return;
    await PeerAgentClientService.instance.refreshAgentList(widget.peerId);
    await _load(quiet: true);
  }

  Future<void> _removeAgent(PeerAgentManageEntry entry) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.peerSettings_removeAgent),
        content: Text(l10n.peerSettings_removeAgentConfirm(entry.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.common_delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busyId = entry.id;
      _error = null;
    });
    try {
      final service = PeerAgentClientService.instance;
      final removed = await service.removeAgent(
        peerId: widget.peerId,
        remoteAgentId: entry.id,
        nodeId: widget.nodeId,
      );
      if (!mounted) return;
      if (!removed.ok) {
        setState(() => _error = removed.error ?? 'unknown');
        return;
      }
      await service.refreshAgentList(widget.peerId);
      await _load(quiet: true);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _openChat(PeerAgentManageEntry entry) async {
    final local = _localFor(entry);
    if (local == null) return;
    // 走 ChatNavigationService：桌面端要落进右栏，手机端要从根 Navigator 推，
    // 自己 push 会绕开这两条接线，也会丢掉已有的会话。
    await ChatNavigationService.instance.openAgentConversation(
      agentId: local.id,
      agentName: local.name,
      agentAvatar: local.avatar,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final hiddenEntries = _entries
        .where((entry) => (_localFor(entry)?.hiddenOnThisApp ?? false))
        .toList();
    final visibleEntries =
        _entries.where((entry) => !hiddenEntries.contains(entry)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.peerSettings_sectionAgents,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ),
              if (widget.isPeerConnected)
                TextButton.icon(
                  onPressed: _createAgent,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(l10n.peerSettings_newAgent),
                ),
            ],
          ),
        ),
        // 离线时照常显示本机缓存，只加一行说明，不把整块换成离线文案。
        if (!widget.isPeerConnected && _entries.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              l10n.peerSettings_agentCacheOffline,
              style:
                  TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
            ),
          ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (_entries.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              widget.isPeerConnected
                  ? l10n.peerSettings_noManagedAgents
                  : l10n.peerSettings_agentManageOffline,
              style:
                  TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
            ),
          )
        else ...[
          ...visibleEntries.map((entry) => _buildTile(l10n, entry)),
          if (hiddenEntries.isNotEmpty) _buildHiddenRow(l10n, hiddenEntries),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _errorText(l10n, _error!),
              style: TextStyle(color: colorScheme.error, fontSize: 12),
            ),
          ),
      ],
    );
  }

  /// 原始错误码对用户没意义，也不该把远端字符串直接贴到界面上。
  String _errorText(AppLocalizations l10n, String error) {
    switch (error) {
      case 'unsupported':
        return l10n.peerSettings_agentManageUnsupported;
      case 'timeout':
        return l10n.peerSettings_agentOpTimeout;
      case 'offline':
        return l10n.peerSettings_agentManageOffline;
      default:
        return l10n.peerSettings_agentOpFailed(error);
    }
  }

  /// 被隐藏的 Agent 默认收成一行，展开后才逐个操作。
  Widget _buildHiddenRow(
    AppLocalizations l10n,
    List<PeerAgentManageEntry> entries,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    if (!_showHidden) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                l10n.peerSettings_hiddenAgentCount(entries.length),
                style: TextStyle(
                    fontSize: 12, color: colorScheme.onSurfaceVariant),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _showHidden = true),
              child: Text(l10n.peerSettings_showHiddenAgents),
            ),
          ],
        ),
      );
    }
    return Column(
      children: entries.map((entry) => _buildTile(l10n, entry)).toList(),
    );
  }

  Widget _buildTile(
    AppLocalizations l10n,
    PeerAgentManageEntry entry,
  ) {
    final local = _localFor(entry);
    final busy = _busyId == entry.id;
    final hidden = local?.hiddenOnThisApp ?? false;
    final String statusLabel;
    final Color statusColor;
    final onlineColor = AppColors.onlineFor(Theme.of(context).brightness);
    if (hidden) {
      statusLabel = l10n.peerSettings_agentHiddenOnApp;
      statusColor = Colors.grey;
    } else if (entry.manageable) {
      if (!entry.enabled) {
        statusLabel = l10n.peerSettings_agentDisabled;
        statusColor = Colors.grey;
      } else if (entry.running) {
        statusLabel = l10n.peerSettings_agentRunning;
        statusColor = onlineColor;
      } else {
        statusLabel = l10n.peerSettings_agentStopped;
        statusColor = Colors.orange;
      }
    } else if (local?.isOnline == true) {
      statusLabel = l10n.status_online;
      statusColor = onlineColor;
    } else {
      statusLabel = l10n.status_offline;
      statusColor = Colors.grey;
    }

    return ListTile(
      leading: AgentListAvatar(
        avatar: local?.avatar ?? '',
        name: entry.name,
      ),
      title: Text(entry.name),
      subtitle: Text(
        [
          if (entry.engine.isNotEmpty) entry.engine,
          statusLabel,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: statusColor, fontSize: 12),
      ),
      onTap: local == null ? null : () => _openChat(entry),
      // 开关和删除紧挨着容易误触，收进 ⋮ 菜单，菜单项自带说明。
      trailing: busy
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _buildTileMenu(l10n, entry, local, hidden),
    );
  }

  Widget? _buildTileMenu(
    AppLocalizations l10n,
    PeerAgentManageEntry entry,
    RemoteAgent? local,
    bool hidden,
  ) {
    final canManage = entry.manageable && widget.isPeerConnected;
    if (local == null && !canManage) return null;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 20),
      tooltip: l10n.common_more,
      onSelected: (value) => _onTileAction(value, entry, local, hidden),
      itemBuilder: (context) => [
        if (local != null)
          PopupMenuItem(
            value: 'chat',
            child: _menuRow(
                Icons.chat_bubble_outline, l10n.contacts_actionSendMessage),
          ),
        if (local != null)
          PopupMenuItem(
            value: hidden ? 'show' : 'hide',
            child: _menuRow(
              hidden
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              hidden
                  ? l10n.contacts_actionShowOnApp
                  : l10n.contacts_actionHideOnApp,
            ),
          ),
        if (canManage)
          PopupMenuItem(
            value: 'remove',
            child: _menuRow(
              Icons.delete_outline,
              l10n.peerSettings_removeAgent,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
      ],
    );
  }

  Widget _menuRow(IconData icon, String label, {Color? color}) => Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Text(label, style: color == null ? null : TextStyle(color: color)),
        ],
      );

  Future<void> _onTileAction(
    String value,
    PeerAgentManageEntry entry,
    RemoteAgent? local,
    bool hidden,
  ) async {
    switch (value) {
      case 'chat':
        await _openChat(entry);
        break;
      case 'hide':
      case 'show':
        if (local != null) await _setVisibleOnApp(local, hidden);
        break;
      case 'remove':
        await _removeAgent(entry);
        break;
    }
  }
}
