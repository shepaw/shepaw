import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/remote_agent.dart';
import '../peer/services/peer_attachment_placement.dart';
import '../services/logger_service.dart';
import '../storage/device_identity.dart';
import '../storage/memory_paths.dart';
import '../storage/runtime_paths.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import '../storage/workspace_binding_service.dart';
import '../theme/app_theme.dart';
import 'storage_browser_screen.dart';

/// 会话面板里的 agent 专属储物袋。
///
/// 主储物袋的「智能体」分区是整机混在一起的。这里只列这个 agent
/// 自己的私有袋：运行时、认知、自己的工具，以及已挂载的工作区。
/// 产物 / 附件只是运行时里的两块，不再单独当成整袋。
class AgentStorageBagScreen extends StatefulWidget {
  const AgentStorageBagScreen({
    super.key,
    required this.ownerId,
    required this.displayName,
    this.agent,
  });

  /// `runtime/<ownerId>/` 与 `cognition/<ownerId>/` 的第一段。
  final String ownerId;

  final String displayName;

  /// 非空且为 peer agent 时，按宿主 device 树浏览本机缓存。
  final RemoteAgent? agent;

  @override
  State<AgentStorageBagScreen> createState() => _AgentStorageBagScreenState();
}

class _AgentStorageBagScreenState extends State<AgentStorageBagScreen> {
  static const _tag = 'AgentStorageBag';

  final _log = LoggerService();

  bool _loading = true;
  String? _error;
  String _deviceId = '';
  String _ownerId = '';
  bool _preferLocalCache = false;
  List<String> _workspaceIds = const [];
  bool _hasLegacyMemory = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final placed = await _resolvePlacement();
      final workspaces = await WorkspaceBindingService.instance.peekBoundIds(
        placed.ownerId,
        deviceId: placed.deviceId,
      );
      final legacy = await _legacyMemoryExists(
        placed.deviceId,
        placed.ownerId,
        placed.preferLocalCache,
      );
      if (!mounted) return;
      setState(() {
        _deviceId = placed.deviceId;
        _ownerId = placed.ownerId;
        _preferLocalCache = placed.preferLocalCache;
        _workspaceIds = workspaces;
        _hasLegacyMemory = legacy;
        _loading = false;
      });
    } catch (e) {
      _log.warning('load agent bag failed: $e', tag: _tag);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<({String deviceId, String ownerId, bool preferLocalCache})>
      _resolvePlacement() async {
    var deviceId = await DeviceIdentity.deviceId();
    var ownerId = widget.ownerId;
    var preferLocalCache = false;
    final agent = widget.agent;
    if (agent != null && agent.isPeerAgent) {
      final placement = await resolvePeerAttachmentPlacement(
        agent: agent,
        localChannelId: '',
      );
      if (placement != null) {
        deviceId = placement.deviceId;
        ownerId = placement.ownerId;
        preferLocalCache = true;
      } else {
        final remote = agent.remoteAgentId?.trim();
        if (remote != null && remote.isNotEmpty) ownerId = remote;
      }
    }
    return (
      deviceId: deviceId,
      ownerId: ownerId,
      preferLocalCache: preferLocalCache,
    );
  }

  Future<bool> _legacyMemoryExists(
    String deviceId,
    String ownerId,
    bool preferLocalCache,
  ) async {
    try {
      final entries = await StoreService.instance.listDevice(
        deviceId: deviceId,
        space: StoreSpace.memory,
        prefix: '${MemoryPaths.agentRoot(ownerId)}/',
        limit: 20,
        computeHash: false,
        preferLocalCache: preferLocalCache,
      );
      return entries.any((e) => !e.isDir);
    } catch (_) {
      return false;
    }
  }

  void _openSpace({
    required String space,
    required String path,
    required String title,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StorageBrowserScreen(
          deviceId: _deviceId.isNotEmpty ? _deviceId : null,
          preferLocalCache: _preferLocalCache,
          readOnly: _preferLocalCache,
          initialSpace: space,
          initialPath: path,
          lockToInitialEntry: true,
          title: '${widget.displayName} · $title',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // 从当前 agent 进来，左边会话列表或系统返回已经能离开。
    // 不再加一条带标题的导航栏。
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                const Spacer(),
                IconButton(
                  tooltip: MaterialLocalizations.of(context)
                      .refreshIndicatorSemanticLabel,
                  icon: const Icon(Icons.refresh),
                  onPressed: _loading ? null : _load,
                ),
              ],
            ),
            Expanded(child: _buildBody(l10n)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    final owner = _ownerId.isNotEmpty ? _ownerId : widget.ownerId;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _spaceRow(
            icon: Icons.bolt_outlined,
            title: l10n.storage_spaceRuntime,
            subtitle: l10n.agentBag_runtimeHint,
            onTap: () => _openSpace(
              space: StoreSpace.runtime,
              path: RuntimePaths.runtimeRoot(owner),
              title: l10n.storage_spaceRuntime,
            ),
          ),
          _spaceRow(
            icon: Icons.psychology_outlined,
            title: l10n.storage_spaceCognition,
            subtitle: l10n.agentBag_cognitionHint,
            onTap: () => _openSpace(
              space: StoreSpace.cognition,
              path: MemoryPaths.agentRoot(owner),
              title: l10n.storage_spaceCognition,
            ),
          ),
          _spaceRow(
            icon: Icons.build_outlined,
            title: l10n.storage_spaceTools,
            subtitle: l10n.agentBag_toolsHint,
            onTap: () => _openSpace(
              space: StoreSpace.tools,
              path:
                  '${StoreSpace.toolsAgentsDir}/${RuntimePaths.sanitizeSegment(owner)}',
              title: l10n.storage_spaceTools,
            ),
          ),
          ..._workspaceRows(l10n),
          if (_hasLegacyMemory)
            _spaceRow(
              icon: Icons.history,
              title: l10n.agentBag_legacyMemory,
              subtitle: l10n.agentBag_legacyMemoryHint,
              onTap: () => _openSpace(
                space: StoreSpace.memory,
                path: MemoryPaths.agentRoot(owner),
                title: l10n.agentBag_legacyMemory,
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  List<Widget> _workspaceRows(AppLocalizations l10n) {
    if (_workspaceIds.isEmpty) {
      return [
        _spaceRow(
          icon: Icons.work_outline,
          title: l10n.storage_spaceWorkspaces,
          subtitle: l10n.agentBag_workspaceEmpty,
        ),
      ];
    }
    return [
      for (final id in _workspaceIds)
        _spaceRow(
          icon: Icons.work_outline,
          title: _workspaceIds.length == 1 ? l10n.storage_spaceWorkspaces : id,
          subtitle:
              _workspaceIds.length == 1 ? id : l10n.storage_spaceWorkspaces,
          onTap: () => _openSpace(
            space: StoreSpace.workspaces,
            path: id,
            title: l10n.storage_spaceWorkspaces,
          ),
        ),
    ];
  }

  Widget _spaceRow({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return ListTile(
      enabled: enabled,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 20, color: AppColors.primary),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: enabled ? const Icon(Icons.chevron_right) : null,
      onTap: onTap,
    );
  }
}
