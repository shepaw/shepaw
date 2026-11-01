import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/agent_node.dart';
import '../../../models/remote_agent.dart';
import '../../../peer/services/peer_agent_client_service.dart';
import '../../../peer/services/peer_connection_manager.dart';
import '../../../service_locator.dart' show getIt;
import '../../../services/remote_agent_service.dart';
import '../../../storage/agent_workspace_uris.dart';
import '../../../storage/host_pouch_target.dart';
import '../../../storage/store_protocol.dart';
import '../../../widgets/host_directory_picker.dart';
import '../../storage_directory_opener.dart';
import 'agent_detail_widgets.dart';

/// 工作区卡片：主机上挂载的目录（主 + 附加）。
///
/// 详情页用 [editable]=false 只读展示；编辑页对可管理实例用 [editable]=true，
/// 改主工作区 / 增删附加目录会写回主机，并让运行中的实例重启。
class AgentWorkspaceSection extends StatefulWidget {
  const AgentWorkspaceSection({
    super.key,
    required this.agent,
    required this.editable,
    this.onAgentChanged,
    this.onEditTap,
  });

  final RemoteAgent agent;
  final bool editable;
  final Future<void> Function()? onAgentChanged;

  /// 只读模式下的「去编辑」入口（仅可管理实例）。
  final VoidCallback? onEditTap;

  @override
  State<AgentWorkspaceSection> createState() => _AgentWorkspaceSectionState();
}

class _AgentWorkspaceSectionState extends State<AgentWorkspaceSection> {
  Future<List<String>>? _urisFuture;

  @override
  void initState() {
    super.initState();
    _urisFuture = collectAgentWorkspaceUris(widget.agent);
  }

  @override
  void didUpdateWidget(AgentWorkspaceSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agent.metadata != widget.agent.metadata ||
        oldWidget.agent.id != widget.agent.id) {
      _urisFuture = collectAgentWorkspaceUris(widget.agent);
    }
  }

  void _reload() {
    setState(() {
      _urisFuture = collectAgentWorkspaceUris(widget.agent);
    });
  }

  Future<void> _refreshAgentRow() async {
    final latest =
        await getIt<RemoteAgentService>().getAgentById(widget.agent.id);
    if (latest == null || !mounted) return;
    await widget.onAgentChanged?.call();
  }

  // ── 打开 ─────────────────────────────────────────────────────────────

  Future<void> _open(String? preferredUri) async {
    final l10n = AppLocalizations.of(context);
    var uris = await collectAgentWorkspaceUris(widget.agent);
    final peerId = widget.agent.sourcePeerId;
    if (primaryWorkspaceUri(uris) == null &&
        widget.agent.isPeerAgent &&
        peerId != null &&
        PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
      await PeerAgentClientService.instance.refreshAgentList(peerId);
      if (!mounted) return;
      await widget.onAgentChanged?.call();
      if (!mounted) return;
      uris = await collectAgentWorkspaceUris(widget.agent);
    }
    String? rawUri;
    if (preferredUri != null) {
      final key =
          (canonicalizeStoreWorkspaceUri(preferredUri) ?? preferredUri)
              .replaceAll(RegExp(r'/+$'), '');
      for (final u in uris) {
        final uk = (canonicalizeStoreWorkspaceUri(u) ?? u)
            .replaceAll(RegExp(r'/+$'), '');
        if (uk == key) {
          rawUri = u;
          break;
        }
      }
      rawUri ??= preferredUri;
    }
    rawUri ??= primaryWorkspaceUri(uris);
    if (!mounted) return;
    if (rawUri == null) {
      _snack(l10n.agentDetail_noWorkspaceToOpen);
      return;
    }
    final uri = canonicalizeStoreWorkspaceUri(rawUri) ?? rawUri;
    final openerContext = context;
    try {
      final parsed = parseStoreUri(uri, allowEmptyPath: true);
      registerStorageDirectoryOpener();
      final deviceId = await resolveStoreDevice(parsed.space);
      if (!mounted) return;
      await openStorageDirectoryInBrowser(
        openerContext,
        space: parsed.space,
        deviceId: deviceId,
        path: parsed.path,
        peerIdHint: widget.agent.sourcePeerId,
      );
    } catch (e) {
      if (!mounted) return;
      _snack(l10n.agentDetail_openWorkspaceFailed('$e'));
    }
  }

  // ── 目录浏览（远端 Hub 或本机）───────────────────────────────────────

  Future<String?> _pickDirectory({required String title}) {
    final l10n = AppLocalizations.of(context);
    final peerId = widget.agent.sourcePeerId;
    final nodeId = AgentNodeInfo.of(widget.agent).nodeId;

    Future<HostFsBrowseResult> browse(String? path) async {
      if (peerId == null ||
          !PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
        throw Exception(l10n.chat_peerDeviceOffline);
      }
      final result = await PeerAgentClientService.instance.browseRemoteFs(
        peerId: peerId,
        path: path,
        nodeId: nodeId,
      );
      if (!result.ok) {
        final err = result.error ?? 'browse failed';
        if (result.unsupported || err == 'timeout') {
          throw Exception(l10n.agentDetail_browseUnsupported);
        }
        throw Exception(err);
      }
      return HostFsBrowseResult(
        path: result.path,
        parent: result.parent,
        entries: [
          for (final e in result.entries)
            HostFsBrowseEntry(name: e.name, path: e.path),
        ],
      );
    }

    return showHostDirectoryPicker(context: context, browse: browse, title: title);
  }

  Future<void> _setPrimary() async {
    final l10n = AppLocalizations.of(context);
    final path = await _pickDirectory(title: l10n.agentDetail_setPrimaryWorkspace);
    if (path == null || !mounted) return;
    await _apply(
      () => PeerAgentClientService.instance.setCwd(
        peerId: widget.agent.sourcePeerId!,
        remoteAgentId: widget.agent.remoteAgentId!,
        cwd: path,
      ),
    );
  }

  Future<void> _addAdditional() async {
    final l10n = AppLocalizations.of(context);
    final path = await _pickDirectory(title: l10n.agentDetail_addWorkspace);
    if (path == null || !mounted) return;
    final current = await _currentAdditional();
    if (current.contains(path)) {
      _snack(l10n.agentDetail_workspaceDuplicate);
      return;
    }
    await _applyAdditional([...current, path]);
  }

  Future<void> _removeAdditional(String uri) async {
    final l10n = AppLocalizations.of(context);
    final path = absolutePathFromWorkspaceUri(uri);
    if (path == null) {
      _snack(l10n.agentDetail_workspaceUnresolved);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.agentDetail_removeWorkspace),
        content: Text(l10n.agentDetail_removeWorkspaceConfirm(path)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.common_delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final current = await _currentAdditional();
    await _applyAdditional(current.where((p) => p != path).toList());
  }

  Future<List<String>> _currentAdditional() async {
    final fromMeta = additionalDirectoriesFromMetadata(widget.agent.metadata);
    if (fromMeta.isNotEmpty) return fromMeta;
    final uris = await collectAgentWorkspaceUris(widget.agent);
    final out = <String>[];
    for (var i = 1; i < uris.length; i++) {
      final path = absolutePathFromWorkspaceUri(uris[i]);
      if (path != null) out.add(path);
    }
    return out;
  }

  Future<void> _applyAdditional(List<String> directories) async {
    await _apply(
      () => PeerAgentClientService.instance.setAdditionalDirectories(
        peerId: widget.agent.sourcePeerId!,
        remoteAgentId: widget.agent.remoteAgentId!,
        directories: directories,
      ),
    );
  }

  Future<void> _apply(
    Future<PeerAgentManageResult> Function() call,
  ) async {
    final l10n = AppLocalizations.of(context);
    final peerId = widget.agent.sourcePeerId;
    final remoteId = widget.agent.remoteAgentId;
    if (peerId == null || remoteId == null) return;
    if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
      _snack(l10n.chat_peerDeviceOffline);
      return;
    }
    _showBusy();
    final result = await call();
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!mounted) return;
    if (!result.ok) {
      _snack(l10n.agentDetail_workspaceUpdateFailed(result.error ?? 'unknown'));
      return;
    }
    await PeerAgentClientService.instance.refreshAgentList(peerId);
    await _refreshAgentRow();
    if (!mounted) return;
    _snack(l10n.agentDetail_workspaceUpdated);
    _reload();
  }

  void _showBusy() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<String>>(
      future: _urisFuture,
      builder: (context, snapshot) {
        final uris = snapshot.data ?? const <String>[];
        return agentCard(
          context: context,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: agentSectionTitle(
                  context,
                  icon: Icons.folder_open_outlined,
                  title: l10n.agentDetail_workspaceSection,
                  trailing: widget.onEditTap == null
                      ? null
                      : TextButton.icon(
                          onPressed: widget.onEditTap,
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          label: Text(l10n.agentDetail_editTooltip),
                        ),
                ),
              ),
              const SizedBox(height: 4),
              if (uris.isEmpty)
                ListTile(
                  leading: Icon(
                    Icons.folder_off_outlined,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  title: Text(l10n.agentDetail_noWorkspace),
                  subtitle: widget.editable
                      ? Text(
                          l10n.agentDetail_workspaceEditHint,
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        )
                      : null,
                ),
              for (var i = 0; i < uris.length; i++)
                ListTile(
                  leading: Icon(
                    i == 0
                        ? Icons.folder_special_outlined
                        : Icons.folder_open_outlined,
                    color: colorScheme.primary,
                  ),
                  title: Text(
                    i == 0
                        ? l10n.agentDetail_primaryWorkspace
                        : l10n.agentDetail_additionalWorkspace(i),
                  ),
                  subtitle: Text(
                    _displayPath(uris[i]),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  trailing: widget.editable && i > 0
                      ? IconButton(
                          tooltip: l10n.agentDetail_removeWorkspace,
                          icon:
                              Icon(Icons.remove_circle_outline, color: colorScheme.error),
                          onPressed: () => unawaited(_removeAdditional(uris[i])),
                        )
                      : const Icon(Icons.chevron_right, size: 18),
                  onTap: () => unawaited(_open(uris[i])),
                ),
              if (widget.editable) ...[
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    Icons.create_new_folder_outlined,
                    color: colorScheme.primary,
                  ),
                  title: Text(
                    uris.isEmpty
                        ? l10n.agentDetail_setPrimaryWorkspace
                        : l10n.agentDetail_addWorkspace,
                  ),
                  subtitle: Text(
                    l10n.agentDetail_workspaceRestartHint,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: const Icon(Icons.add),
                  onTap:
                      uris.isEmpty ? () => unawaited(_setPrimary()) : () => unawaited(_addAdditional()),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  String _displayPath(String rawUri) {
    final uri = canonicalizeStoreWorkspaceUri(rawUri) ?? rawUri;
    try {
      final parsed = parseStoreUri(uri, allowEmptyPath: true);
      final path = parsed.path.replaceAll(RegExp(r'/+$'), '');
      if (path.isEmpty) return uri;
      return '/$path';
    } catch (_) {
      return uri;
    }
  }
}
