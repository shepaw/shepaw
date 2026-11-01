import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/agent_node.dart';
import '../../models/remote_agent.dart';
import '../../services/chat_navigation_service.dart';
import '../../services/she_service.dart';
import '../../storage/agent_storage_bag_opener.dart';
import '../../widgets/avatar_image.dart';
import '../agent_resume_edit_screen.dart';
import '../agent_soul_edit_screen.dart';
import 'agent_detail_kind.dart';
import 'agent_edit_screen.dart';
import 'agent_runtime_controller.dart';
import 'widgets/agent_detail_widgets.dart';
import 'widgets/agent_model_picker.dart';
import 'widgets/agent_workspace_section.dart';

/// Agent 详情页：**只读**。
///
/// 这里不放任何写控件（简历和 Soul 的卡片只是打开各自的页面，能不能改由那个页面
/// 自己按主机给的权限决定）。要改配置一律进 [AgentEditScreen]。
/// 背景与取舍见 `.ai_workspace/AGENT_DETAIL_EDIT_REDESIGN.md`。
class AgentDetailScreen extends StatefulWidget {
  const AgentDetailScreen({super.key, required this.agent});

  final RemoteAgent agent;

  @override
  State<AgentDetailScreen> createState() => _AgentDetailScreenState();
}

class _AgentDetailScreenState extends State<AgentDetailScreen> {
  late RemoteAgent _agent;
  late AgentRuntimeController _runtime;

  @override
  void initState() {
    super.initState();
    _agent = widget.agent;
    _runtime = AgentRuntimeController(_agent);
    _runtime.addListener(_onRuntimeChanged);
    _runtime.subscribe();
    unawaited(_runtime.refreshAll());
  }

  @override
  void dispose() {
    _runtime.removeListener(_onRuntimeChanged);
    _runtime.dispose();
    super.dispose();
  }

  void _onRuntimeChanged() {
    if (mounted) setState(() {});
  }

  AgentDetailCapabilities get _caps => AgentDetailCapabilities.of(_agent);

  Future<void> _refreshRow() async {
    await _runtime.refreshAgentRow();
    if (!mounted) return;
    setState(() => _agent = _runtime.agent);
  }

  Future<void> _openEdit({AgentEditSection? section}) async {
    final result = await Navigator.push<Object?>(
      context,
      MaterialPageRoute(
        builder: (_) => AgentEditScreen(
          agent: _agent,
          runtime: _runtime,
          initialSection: section,
        ),
      ),
    );
    if (!mounted) return;
    if (result == 'deleted') {
      Navigator.pop(context, 'deleted');
      return;
    }
    await _refreshRow();
  }

  Future<void> _openResume() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => AgentResumeEditScreen(
          agent: _agent,
          prefetchedResume:
              (_agent.bio ?? '').isNotEmpty ? _agent.bio : null,
          prefetchedEditable: _agent.isPeerAgent
              ? _agent.metadata['resume_editable'] == true
              : null,
        ),
      ),
    );
    if (!mounted || result == null) return;
    await _refreshRow();
  }

  Future<void> _openSoul() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => AgentSoulEditScreen(
          agent: _agent,
          prefetchedSoul:
              !_runtime.soulLoading && !_runtime.soulFetchFailed
                  ? _runtime.soul
                  : null,
          prefetchedEditable: _runtime.soulEditable,
          prefetchFailed: !_runtime.soulLoading && _runtime.soulFetchFailed,
        ),
      ),
    );
    if (!mounted) return;
    unawaited(_runtime.refreshSoul());
  }

  Future<void> _openStorageBag() => openAgentStorageBag(
        context,
        ownerId: _agent.id,
        displayName: _agent.name,
      );

  Future<void> _startConversation() =>
      ChatNavigationService.instance.openAgentConversation(
        agentId: _agent.id,
        agentName: _agent.name,
        agentAvatar: _agent.avatar,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.agentDetail_title),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: l10n.agentDetail_editTooltip,
            onPressed: () => unawaited(_openEdit()),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(l10n),
                  const SizedBox(height: 16),
                  _buildRuntimeCard(l10n),
                  if (_caps.showWorkspace) ...[
                    const SizedBox(height: 16),
                    AgentWorkspaceSection(
                      agent: _agent,
                      editable: false,
                      onEditTap:
                          _caps.canEditWorkspace ? () => unawaited(_openEdit(section: AgentEditSection.workspace)) : null,
                    ),
                  ],
                  const SizedBox(height: 16),
                  _buildContentCard(l10n),
                  const SizedBox(height: 16),
                  _buildTechInfoCard(l10n, colorScheme),
                ],
              ),
            ),
          ),
          _buildBottomBar(l10n, colorScheme),
        ],
      ),
    );
  }

  Widget _buildHeader(AppLocalizations l10n) {
    final node = AgentNodeInfo.of(_agent);
    final engine = (_agent.metadata['engine'] as String?)?.trim() ?? '';
    return Column(
      children: [
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(25),
          ),
          alignment: Alignment.center,
          child: AvatarImage(
            avatar: _agent.avatar.isNotEmpty ? _agent.avatar : '🤖',
            size: 100,
            borderRadius: 25,
            fallback: const Icon(Icons.smart_toy, size: 60),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          SheService.resolveDisplayName(_agent.name, l10n.she_name),
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            AgentStatusChip(status: _runtime.status),
            if (_agent.isPeerAgent)
              AgentSourceChip(
                sourceName: _agent.sourcePeerName ?? l10n.peerPairing_title,
              ),
            if (engine.isNotEmpty) _buildEngineChip(engine),
          ],
        ),
        if (_runtime.status == AgentDetailStatus.hostOffline) ...[
          const SizedBox(height: 8),
          Text(
            l10n.agentDetail_hostOffline,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ],
        if (node.nodeName != null) ...[
          const SizedBox(height: 8),
          Text(
            '${l10n.agentDetail_node} · ${node.nodeName}',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ],
      ],
    );
  }

  Widget _buildEngineChip(String engine) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.smart_toy_outlined, size: 14, color: colorScheme.primary),
          const SizedBox(width: 6),
          Text(engine, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildRuntimeCard(AppLocalizations l10n) {
    final modelText = _runtime.modelsLoading && _runtime.models.isEmpty
        ? l10n.common_loading
        : _modelDisplayName() ?? l10n.chat_mainModelUnset;
    final modeText = _runtime.modes.isEmpty
        ? (_runtime.peerLinkUp ? l10n.agentDetail_noModes : l10n.agentDetail_peerOffline)
        : _modeDisplayName() ?? l10n.agentDetail_mode;
    return agentCard(
      context: context,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: agentSectionTitle(
              context,
              icon: Icons.tune_outlined,
              title: l10n.agentDetail_runtimeSection,
            ),
          ),
          AgentRuntimeSummaryRow(
            icon: Icons.memory_outlined,
            label: l10n.agentDetail_model,
            value: modelText,
            onTap: () => unawaited(_openEdit(section: AgentEditSection.runtime)),
          ),
          if (_caps.showModeAndSync) ...[
            AgentRuntimeSummaryRow(
              icon: Icons.tune_outlined,
              label: l10n.agentDetail_mode,
              value: modeText,
              onTap: () => unawaited(_openEdit(section: AgentEditSection.runtime)),
            ),
            AgentRuntimeSummaryRow(
              icon: Icons.sync_outlined,
              label: l10n.agentDetail_sessionSync,
              value: _runtime.sessionSyncEnabled
                  ? l10n.agentDetail_syncOn
                  : l10n.agentDetail_syncOff,
              onTap: () => unawaited(_openEdit(section: AgentEditSection.runtime)),
            ),
          ],
        ],
      ),
    );
  }

  String? _modelDisplayName() {
    final current = _runtime.currentModel;
    if (current == null) {
      return _runtime.models.length == 1 ? _runtime.models.first.displayName : null;
    }
    for (final m in _runtime.models) {
      if (m.value == current) return m.displayName;
    }
    return current;
  }

  String? _modeDisplayName() {
    final current = _runtime.currentMode;
    if (current == null) {
      return _runtime.modes.length == 1 ? _runtime.modes.first.displayName : null;
    }
    for (final m in _runtime.modes) {
      if (m.value == current) return m.displayName;
    }
    return current;
  }

  Widget _buildContentCard(AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    final soul = _runtime.soul.trim();
    final soulSubtitle = _runtime.soulLoading
        ? l10n.common_loading
        : _runtime.soulFetchFailed
            ? l10n.chat_soulFetchFailed
            : soul.isEmpty
                ? l10n.chat_soulEmpty
                : (soul.length > 80 ? '${soul.substring(0, 80)}…' : soul);
    final resume = (_agent.bio ?? '').trim();

    return agentCard(
      context: context,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Column(
        children: [
          ListTile(
            leading:
                Icon(Icons.description_outlined, color: colorScheme.primary),
            title: Text(l10n.groupMemberDetail_resume),
            subtitle: Text(
              resume.isEmpty ? l10n.resumeEdit_emptyHint : resume,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: resume.isEmpty ? colorScheme.onSurfaceVariant : null,
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => unawaited(_openResume()),
          ),
          const Divider(height: 1),
          ListTile(
            leading:
                Icon(Icons.psychology_outlined, color: colorScheme.primary),
            title: Text(l10n.agentDetail_systemPrompt),
            subtitle: Text(
              soulSubtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => unawaited(_openSoul()),
          ),
          const Divider(height: 1),
          ListTile(
            leading:
                Icon(Icons.auto_stories_outlined, color: colorScheme.primary),
            title: Text(l10n.chat_storageSpace),
            subtitle: Text(
              l10n.agentDetail_storageBagSub,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => unawaited(_openStorageBag()),
          ),
        ],
      ),
    );
  }

  Widget _buildTechInfoCard(AppLocalizations l10n, ColorScheme colorScheme) {
    final node = AgentNodeInfo.of(_agent);
    final remoteId = _agent.remoteAgentId;
    return agentCard(
      context: context,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(l10n.agentDetail_techInfo),
        childrenPadding: const EdgeInsets.only(bottom: 12),
        children: [
          AgentInfoRow(label: l10n.agentDetail_agentId, value: _agent.id),
          const SizedBox(height: 8),
          if (remoteId != null && remoteId.isNotEmpty) ...[
            AgentInfoRow(
              label: l10n.agentDetail_hostAgentId,
              value: remoteId,
            ),
            const SizedBox(height: 8),
          ],
          AgentInfoRow(
            label: l10n.agentDetail_sourceDevice,
            value: _agent.sourcePeerName ?? _agent.sourcePeerId ?? '-',
          ),
          if (node.nodeName != null) ...[
            const SizedBox(height: 8),
            AgentInfoRow(label: l10n.agentDetail_node, value: node.nodeName!),
          ],
          const SizedBox(height: 8),
          AgentInfoRow(
            label: l10n.addAgent_engine,
            value: (_agent.metadata['engine'] as String?) ?? '-',
          ),
          const SizedBox(height: 8),
          AgentInfoRow(
            label: l10n.agentDetail_createdAt,
            value: _formatTimestamp(_agent.createdAt),
          ),
          const SizedBox(height: 8),
          AgentInfoRow(
            label: l10n.agentDetail_updatedAt,
            value: _formatTimestamp(_agent.updatedAt),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(AppLocalizations l10n, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: () => unawaited(_startConversation()),
          icon: const Icon(Icons.chat),
          label: Text(l10n.agentDetail_startConversation),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ),
    );
  }

  String _formatTimestamp(int timestampMs) {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final time = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return l10n.agentDetail_justNow;
    if (diff.inMinutes < 60) return l10n.agentDetail_minutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return l10n.agentDetail_hoursAgo(diff.inHours);
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
  }
}
