import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/instruction_set.dart';
import '../service_locator.dart';
import '../services/chat_navigation_service.dart';
import '../services/chat_service.dart';
import '../services/composer_draft_service.dart';
import '../services/instruction_set_service.dart';
import '../services/local_database_service.dart';
import '../services/local_user_identity.dart';
import '../services/she_service.dart';
import 'instruction_set_editor_screen.dart';

/// 指令集管理页：查看 / 新建 / 编辑 / 删除 / 一键执行可复用的任务指令。
///
/// 桌面端嵌入右侧面板（[DesktopHomeScreen]），移动端作为独立页面打开。
/// 「执行」会打开与所属 Agent 的会话并预填指令内容，由该 Agent 执行。
///
/// 当从某个具体聊天（[channelId] 非空）打开时，执行指令会使用当前聊天的
/// agent / 群会话：预填当前会话的输入框并返回，而不是跳转到指令所属 agent。
class InstructionSetScreen extends StatefulWidget {
  /// 当前聊天上下文。非空表示从具体聊天内打开，执行指令时预填当前会话。
  final String? channelId;

  /// 当前聊天的 agent（DM 时有效；群聊为 null，走 [groupFamilyId]）。
  final String? agentId;

  /// 当前群聊的 group family id（群聊时有效）。
  final String? groupFamilyId;

  const InstructionSetScreen({
    super.key,
    this.channelId,
    this.agentId,
    this.groupFamilyId,
  });

  @override
  State<InstructionSetScreen> createState() => _InstructionSetScreenState();
}

class _InstructionSetScreenState extends State<InstructionSetScreen> {
  final _service = InstructionSetService.instance;
  final _db = LocalDatabaseService();

  List<InstructionSet>? _items;
  final Map<String, String> _ownerNames = {}; // ownerAgentId -> display name

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final items = await _service.list();
    final agents = await _db.getAllRemoteAgents();

    final names = <String, String>{};
    for (final agent in agents) {
      names[agent.id] = agent.name;
    }
    // 数据库里的 owner_agent_name 快照优先，其次按 agent 表解析。
    for (final item in items) {
      if (item.ownerAgentName.isNotEmpty) {
        names[item.ownerAgentId] = item.ownerAgentName;
      } else if (!names.containsKey(item.ownerAgentId)) {
        names[item.ownerAgentId] = item.ownerAgentId;
      }
    }

    if (!mounted) return;
    setState(() {
      _items = items;
      _ownerNames.addAll(names);
    });
  }

  AppLocalizations get _l10n => AppLocalizations.of(context);

  String _ownerLabel(String ownerId) {
    if (ownerId == SheService.sheId) return _l10n.she_name;
    return _ownerNames[ownerId] ?? ownerId;
  }

  String _formatTime(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final local = dt.toLocal();
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final items = _items;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.instructionSet_title),
        actions: [
          if (items != null && items.isNotEmpty)
            IconButton(
              tooltip: l10n.common_refresh,
              icon: const Icon(Icons.refresh),
              onPressed: () {
                setState(() => _items = null);
                unawaited(_load());
              },
            ),
          IconButton(
            tooltip: l10n.instructionSet_create,
            icon: const Icon(Icons.add),
            onPressed: _openEditor,
          ),
        ],
      ),
      body: switch (items) {
        null => const Center(child: CircularProgressIndicator()),
        [] => _buildEmpty(),
        _ => _buildList(items),
      },
    );
  }

  Widget _buildEmpty() {
    final l10n = _l10n;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.playlist_add_check_outlined,
              size: 64, color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              l10n.instructionSet_empty,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<InstructionSet> items) {
    final theme = Theme.of(context);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = items[index];
        return Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.secondaryContainer,
              child: Icon(Icons.playlist_add_check_outlined,
                  size: 20, color: theme.colorScheme.onSecondaryContainer),
            ),
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.description != null && item.description!.isNotEmpty)
                  Text(
                    item.description!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 2),
                Text(
                  '${_l10n.instructionSet_ownerLabel} ${_ownerLabel(item.ownerAgentId)}'
                  ' · ${_l10n.instructionSet_updatedLabel} ${_formatTime(item.updatedAt)}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: item.name,
              onSelected: (action) => _onAction(item, action),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'run',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.play_arrow),
                    title: Text(_l10n.instructionSet_run),
                  ),
                ),
                PopupMenuItem(
                  value: 'edit',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.edit_outlined),
                    title: Text(_l10n.common_edit),
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline,
                        color: theme.colorScheme.error),
                    title: Text(
                      _l10n.common_delete,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ),
              ],
            ),
            onTap: () => _showDetail(item),
          ),
        );
      },
    );
  }

  Future<void> _onAction(InstructionSet item, String action) async {
    switch (action) {
      case 'run':
        await _runInstruction(item);
      case 'edit':
        await _openEditor(item: item);
      case 'delete':
        await _confirmDelete(item);
    }
  }

  void _showDetail(InstructionSet item) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _InstructionDetailSheet(
        item: item,
        ownerLabel: _ownerLabel(item.ownerAgentId),
        l10n: _l10n,
        onRun: () {
          Navigator.pop(context);
          unawaited(_runInstruction(item));
        },
        onEdit: () {
          Navigator.pop(context);
          unawaited(_openEditor(item: item));
        },
        onDelete: () {
          Navigator.pop(context);
          unawaited(_confirmDelete(item));
        },
      ),
    );
  }

  // ── 新建 / 编辑 ──────────────────────────────────────────────────────────────

  /// 打开新建 / 编辑页，保存成功后刷新列表。
  Future<void> _openEditor({InstructionSet? item}) async {
    final savedName = await Navigator.push<String>(
      context,
      MaterialPageRoute<String>(
        builder: (_) => InstructionSetEditorScreen(item: item),
      ),
    );
    if (savedName == null || !mounted) return;

    setState(() => _items = null);
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n.instructionSet_saved(savedName))),
      );
    }
  }

  // ── 删除 ─────────────────────────────────────────────────────────────────────

  Future<void> _confirmDelete(InstructionSet item) async {
    final l10n = _l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.instructionSet_deleteTitle),
        content: Text(l10n.instructionSet_deleteBody(item.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.common_delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _service.delete(item.id);
    setState(() => _items = null);
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.instructionSet_deleted(item.name)),
        ),
      );
    }
  }

  // ── 执行：打开与所属 Agent 的会话并预填指令内容 ────────────────────────────

  Future<void> _runInstruction(InstructionSet item) async {
    final l10n = _l10n;
    final chatService = getIt<ChatService>();
    const userId = LocalUserIdentity.id;

    // 从具体聊天内打开：使用当前聊天的 agent / 群会话，不跳转到指令所属 agent。
    final currentChannelId = widget.channelId;
    if (currentChannelId != null && currentChannelId.isNotEmpty) {
      getIt<ComposerDraftService>().setDraft(
        currentChannelId,
        '执行指令「${item.name}」：\n${item.content}',
        agentId: widget.agentId,
        groupFamilyId: widget.groupFamilyId,
        // 气泡只展示指令标题，完整内容作为隐式消息投递给 agent。
        instructionName: item.name,
      );
      if (mounted) Navigator.pop(context);
      return;
    }

    final ownerId = item.ownerAgentId;
    final channelId =
        await chatService.getLatestActiveChannelId(userId, ownerId) ??
            chatService.generateChannelId(userId, ownerId);

    var ownerName = item.ownerAgentName;
    String? ownerAvatar;
    if (ownerId == SheService.sheId) {
      ownerName = l10n.she_name;
      ownerAvatar = SheService.sheAvatar;
    } else {
      final agent = await _db.getRemoteAgentById(ownerId);
      ownerName = (ownerName.isNotEmpty ? ownerName : agent?.name) ?? ownerId;
      ownerAvatar = agent?.avatar;
    }

    getIt<ComposerDraftService>().setDraft(
      channelId,
      '执行指令「${item.name}」：\n${item.content}',
      agentId: ownerId,
      // 气泡只展示指令标题，完整内容作为隐式消息投递给 agent。
      instructionName: item.name,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.instructionSet_runHint)),
      );
    }
    // 桌面端：右侧面板原地切换到所属 Agent 会话；移动端：在指令集页之上
    // 打开所属 Agent 会话（返回键回到指令集页）。
    await ChatNavigationService.instance.openChannel(
      channelId: channelId,
      agentId: ownerId,
      agentName: ownerName,
      agentAvatar: ownerAvatar,
    );
  }
}

/// 指令详情底部面板。
class _InstructionDetailSheet extends StatelessWidget {
  const _InstructionDetailSheet({
    required this.item,
    required this.ownerLabel,
    required this.l10n,
    required this.onRun,
    required this.onEdit,
    required this.onDelete,
  });

  final InstructionSet item;
  final String ownerLabel;
  final AppLocalizations l10n;
  final VoidCallback onRun;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.name,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                tooltip: l10n.common_edit,
                icon: const Icon(Icons.edit_outlined),
                onPressed: onEdit,
              ),
              IconButton(
                tooltip: l10n.common_delete,
                icon:
                    Icon(Icons.delete_outline, color: theme.colorScheme.error),
                onPressed: onDelete,
              ),
            ],
          ),
          if (item.description != null && item.description!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(item.description!, style: TextStyle(color: muted)),
          ],
          const SizedBox(height: 4),
          Text(
            '${l10n.instructionSet_ownerLabel} $ownerLabel',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 320),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                item.content,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onRun,
              icon: const Icon(Icons.play_arrow),
              label: Text(l10n.instructionSet_run),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.instructionSet_runHint,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}
