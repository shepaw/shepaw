import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../l10n/app_localizations.dart';
import '../../models/agent_node.dart';
import '../../models/remote_agent.dart';
import '../../peer/services/peer_agent_client_service.dart';
import '../../peer/services/peer_connection_manager.dart';
import '../../service_locator.dart' show getIt;
import '../../services/local_file_storage_service.dart';
import '../../services/remote_agent_service.dart';
import '../../widgets/avatar_image.dart';
import 'agent_detail_kind.dart';
import 'agent_runtime_controller.dart';
import 'widgets/agent_detail_widgets.dart';
import 'widgets/agent_model_picker.dart';
import 'widgets/agent_workspace_section.dart';

/// 打开编辑页时要滚到的分区。
enum AgentEditSection { profile, runtime, workspace, danger }

/// Agent 编辑页。
///
/// 与详情页分开的独立路由：没有模式切换、没有保存按钮、返回键不拦截。
/// 每一项要么立即写回主机（模型 / 模式 / 会话同步 / 工作区 / 改名），
/// 要么只改本机显示（头像）。
class AgentEditScreen extends StatefulWidget {
  const AgentEditScreen({
    super.key,
    required this.agent,
    this.runtime,
    this.initialSection,
  });

  final RemoteAgent agent;

  /// 详情页传进来的控制器，共享已加载的模型 / 模式 / Soul，避免重复中继。
  final AgentRuntimeController? runtime;

  final AgentEditSection? initialSection;

  @override
  State<AgentEditScreen> createState() => _AgentEditScreenState();
}

class _AgentEditScreenState extends State<AgentEditScreen> {
  late RemoteAgent _agent;
  late AgentRuntimeController _runtime;
  final _profileKey = GlobalKey();
  final _runtimeKey = GlobalKey();
  final _workspaceKey = GlobalKey();
  final _dangerKey = GlobalKey();

  // 头像编辑
  String _editingAvatar = '';
  bool _avatarSaving = false;
  final ImagePicker _imagePicker = ImagePicker();
  final LocalFileStorageService _fileStorage = LocalFileStorageService();

  bool _removing = false;

  @override
  void initState() {
    super.initState();
    _agent = widget.agent;
    _editingAvatar = _agent.avatar;
    _runtime = widget.runtime ?? AgentRuntimeController(_agent);
    if (widget.runtime == null) _runtime.subscribe();
    _runtime.addListener(_onRuntimeChanged);
    if (widget.runtime == null) unawaited(_runtime.refreshAll());
    final section = widget.initialSection;
    if (section != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(section));
    }
  }

  @override
  void dispose() {
    _runtime.removeListener(_onRuntimeChanged);
    if (widget.runtime == null) _runtime.dispose();
    super.dispose();
  }

  void _onRuntimeChanged() {
    if (mounted) setState(() {});
  }

  AgentDetailCapabilities get _caps => AgentDetailCapabilities.of(_agent);

  void _scrollTo(AgentEditSection section) {
    final key = switch (section) {
      AgentEditSection.profile => _profileKey,
      AgentEditSection.runtime => _runtimeKey,
      AgentEditSection.workspace => _workspaceKey,
      AgentEditSection.danger => _dangerKey,
    };
    final ctx = key.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 250),
      alignment: 0.05,
    );
  }

  // ── 头像（只改本机显示）─────────────────────────────────────────────

  Future<void> _saveAvatar(String avatar) async {
    setState(() => _avatarSaving = true);
    try {
      final metadata = Map<String, dynamic>.from(_agent.metadata);
      // 本地改过头像就打标记，之后主机名单同步不再覆盖。
      metadata['avatar_overridden'] = true;
      final updated = _agent.copyWith(
        avatar: avatar,
        metadata: metadata,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await getIt<RemoteAgentService>().updateAgent(updated);
      if (!mounted) return;
      setState(() {
        _agent = updated;
        _editingAvatar = avatar;
      });
    } finally {
      if (mounted) setState(() => _avatarSaving = false);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final l10n = AppLocalizations.of(context);
    try {
      final image = await _imagePicker.pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (image == null) return;
      final relative = await _fileStorage.saveImage(
        File(image.path),
        type: ResourceType.avatars,
      );
      final fullPath = await _fileStorage.getFullPath(relative);
      if (!mounted) return;
      setState(() => _editingAvatar = fullPath);
      await _saveAvatar(fullPath);
    } catch (e) {
      if (!mounted) return;
      final text = source == ImageSource.camera
          ? l10n.agentDetail_cameraFailed('$e')
          : l10n.agentDetail_galleryFailed('$e');
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(text), backgroundColor: Colors.red));
    }
  }

  void _showAvatarPicker() {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.emoji_emotions_outlined),
              title: Text(l10n.agentDetail_selectBuiltinAvatar),
              onTap: () {
                Navigator.pop(ctx);
                _showBuiltinAvatarPicker();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(l10n.agentDetail_selectFromGallery),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_pickImage(ImageSource.gallery));
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: Text(l10n.agentDetail_takePhoto),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_pickImage(ImageSource.camera));
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showBuiltinAvatarPicker() {
    final l10n = AppLocalizations.of(context);
    const avatars = [
      '🤖', '🦾', '🧠', '💡', '🌟', '⚡', '🔮', '🎯',
      '🚀', '🛸', '🌈', '🔥', '💎', '🎨', '🎭', '🎪',
      '🐱', '🐶', '🦊', '🐼', '🦉', '🦋', '🐝', '🐙',
      '👤', '👩‍💻', '🧑‍🔬', '🧑‍🚀', '🧙', '🥷', '🦸', '🤹',
    ];
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.addAgent_selectAvatar),
        content: SizedBox(
          width: double.maxFinite,
          child: GridView.builder(
            shrinkWrap: true,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: avatars.length,
            itemBuilder: (context, index) {
              final avatar = avatars[index];
              return GestureDetector(
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_saveAvatar(avatar));
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: _editingAvatar == avatar
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(avatar, style: const TextStyle(fontSize: 32)),
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.common_cancel),
          ),
        ],
      ),
    );
  }

  // ── 改名（只有可管理实例写得回主机）──────────────────────────────────

  Future<String?> _rename(String name) async {
    final peerId = _agent.sourcePeerId;
    final remoteId = _agent.remoteAgentId;
    if (peerId == null ||
        peerId.isEmpty ||
        remoteId == null ||
        remoteId.isEmpty) {
      return 'peer missing';
    }
    final result = await PeerAgentClientService.instance.renameAgent(
      peerId: peerId,
      remoteAgentId: remoteId,
      name: name,
      nodeId: AgentNodeInfo.of(_agent).nodeId,
    );
    if (!result.ok) return result.error ?? 'unknown';
    final updated = _agent.copyWith(
      name: name,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await getIt<RemoteAgentService>().updateAgent(updated);
    if (!mounted) return null;
    setState(() => _agent = updated);
    return null;
  }

  // ── 危险操作 ────────────────────────────────────────────────────────

  Future<void> _removeFromHost() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.agentDetail_removeFromHost),
        content: Text(l10n.agentDetail_removeFromHostConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(l10n.agentDetail_removeFromHost),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _removing = true);
    final peerId = _agent.sourcePeerId;
    final remoteId = _agent.remoteAgentId;
    if (peerId != null && remoteId != null) {
      final removed = await PeerAgentClientService.instance.removeAgent(
        peerId: peerId,
        remoteAgentId: remoteId,
      );
      if (!removed.ok) {
        if (!mounted) return;
        setState(() => _removing = false);
        _snack(l10n.agentDetail_deleteFailed(removed.error ?? 'unknown'),
            error: true);
        return;
      }
    }
    await getIt<RemoteAgentService>().deleteAgent(_agent.id);
    if (!mounted) return;
    Navigator.pop(context, 'deleted');
  }

  /// 不可管理的外接 agent：只在本机隐藏，主机下一轮同步还会把它带回来。
  Future<void> _hideOnThisApp() async {
    final metadata = Map<String, dynamic>.from(_agent.metadata);
    metadata['hidden_on_this_app'] = true;
    final updated = _agent.copyWith(
      metadata: metadata,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await getIt<RemoteAgentService>().updateAgent(updated);
    PeerConnectionManager.instance.notifyPeerListChanged();
    if (!mounted) return;
    Navigator.pop(context, 'deleted');
  }

  void _snack(String text, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: error ? Colors.red : null,
      ),
    );
  }

  void _onModelFailure(AgentActionFailure failure) {
    final l10n = AppLocalizations.of(context);
    switch (failure) {
      case AgentActionFailure.notSwitchable:
        _snack(l10n.chat_modelConfiguredOnComputer, error: true);
      case AgentActionFailure.peerOffline:
        _snack(l10n.chat_peerDeviceOffline, error: true);
      case AgentActionFailure.failed:
        _snack(l10n.agentDetail_modelSwitchFailed, error: true);
    }
  }

  void _onModeFailure(AgentActionFailure failure) {
    final l10n = AppLocalizations.of(context);
    switch (failure) {
      case AgentActionFailure.peerOffline:
        _snack(l10n.chat_peerDeviceOffline, error: true);
      case AgentActionFailure.notSwitchable:
      case AgentActionFailure.failed:
        _snack(l10n.agentDetail_modeSwitchFailed, error: true);
    }
  }

  Future<void> _setSessionSync(bool enabled) async {
    final l10n = AppLocalizations.of(context);
    final failure = await _runtime.setSessionSync(enabled);
    if (failure != null && mounted) _snack(l10n.agentDetail_sessionSyncFailed, error: true);
  }

  // ── 页面 ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.agentDetail_editTitle), centerTitle: true),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildProfileSection(l10n, colorScheme),
            const SizedBox(height: 16),
            _buildRuntimeSection(l10n),
            if (_caps.showWorkspace) ...[
              const SizedBox(height: 16),
              Container(
                key: _workspaceKey,
                child: AgentWorkspaceSection(
                  agent: _agent,
                  editable: _caps.canEditWorkspace,
                  onAgentChanged: () async {
                    await _runtime.refreshAgentRow();
                    if (mounted) setState(() => _agent = _runtime.agent);
                  },
                ),
              ),
            ],
            if (_caps.showDangerZone) ...[
              const SizedBox(height: 16),
              _buildDangerSection(l10n, colorScheme),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileSection(AppLocalizations l10n, ColorScheme colorScheme) {
    return Container(
      key: _profileKey,
      child: agentCard(
        context: context,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            agentSectionTitle(
              context,
              icon: Icons.info_outline,
              title: l10n.addAgent_basicInfo,
            ),
            const SizedBox(height: 16),
            if (_caps.canEditAvatar) ...[
              Center(
                child: GestureDetector(
                  onTap: _showAvatarPicker,
                  child: Stack(
                    children: [
                      Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(25),
                        ),
                        alignment: Alignment.center,
                        child: _avatarSaving
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : AvatarImage(
                                avatar:
                                    _editingAvatar.isNotEmpty ? _editingAvatar : '🤖',
                                size: 100,
                                borderRadius: 25,
                                fallback: const Icon(Icons.smart_toy, size: 60),
                              ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.camera_alt,
                            size: 18,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  onPressed: _showAvatarPicker,
                  icon: const Icon(Icons.edit, size: 16),
                  label: Text(l10n.agentDetail_changeAvatar),
                ),
              ),
              const SizedBox(height: 16),
            ],
            AgentNameField(
              agent: _agent,
              readOnly: !_caps.canEditName,
              onSubmit: _rename,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRuntimeSection(AppLocalizations l10n) {
    return Container(
      key: _runtimeKey,
      child: agentCard(
        context: context,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            agentSectionTitle(
              context,
              icon: Icons.tune_outlined,
              title: l10n.agentDetail_runtimeSection,
            ),
            const SizedBox(height: 12),
            AgentModelPicker(controller: _runtime, onFailure: _onModelFailure),
            if (_caps.showModeAndSync) ...[
              const Divider(height: 24),
              AgentModePicker(controller: _runtime, onFailure: _onModeFailure),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.sync_outlined),
                title: Text(l10n.agentDetail_sessionSync),
                subtitle: Text(l10n.agentDetail_sessionSyncHint),
                value: _runtime.sessionSyncEnabled,
                onChanged: _runtime.syncSwitching
                    ? null
                    : (value) => unawaited(_setSessionSync(value)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDangerSection(AppLocalizations l10n, ColorScheme colorScheme) {
    final removesFromHost = _caps.removesFromHost;
    return Container(
      key: _dangerKey,
      child: agentCard(
        context: context,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            agentSectionTitle(
              context,
              icon: Icons.warning_amber_outlined,
              title: l10n.agentDetail_dangerSection,
            ),
            const SizedBox(height: 12),
            if (removesFromHost)
              OutlinedButton.icon(
                onPressed: _removing ? null : () => unawaited(_removeFromHost()),
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: Text(l10n.agentDetail_removeFromHost),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              )
            else ...[
              OutlinedButton.icon(
                onPressed: () => unawaited(_hideOnThisApp()),
                icon: Icon(Icons.visibility_off_outlined, color: colorScheme.primary),
                label: Text(l10n.agentDetail_hideOnApp),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.agentDetail_hideOnAppHint,
                style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
