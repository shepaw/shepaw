import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/instruction_set.dart';
import '../models/remote_agent.dart';
import '../service_locator.dart';
import '../services/chat_navigation_service.dart';
import '../services/chat_service.dart';
import '../services/composer_draft_service.dart';
import '../services/instruction_set_service.dart';
import '../services/local_database_service.dart';
import '../services/local_user_identity.dart';
import '../services/she_service.dart';

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
  List<RemoteAgent> _agents = const [];

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
      _agents = agents;
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
            onPressed: _showCreateDialog,
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
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
        await _showEditDialog(item);
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
          unawaited(_showEditDialog(item));
        },
        onDelete: () {
          Navigator.pop(context);
          unawaited(_confirmDelete(item));
        },
      ),
    );
  }

  // ── 新建 / 编辑 ──────────────────────────────────────────────────────────────

  Future<void> _showCreateDialog() async {
    await _showEditorDialog(item: null);
  }

  Future<void> _showEditDialog(InstructionSet item) async {
    await _showEditorDialog(item: item);
  }

  Future<void> _showEditorDialog({InstructionSet? item}) async {
    final l10n = _l10n;
    final nameController = TextEditingController(text: item?.name ?? '');
    final descController =
        TextEditingController(text: item?.description ?? '');
    final contentController =
        TextEditingController(text: item?.content ?? '');
    var ownerId = item?.ownerAgentId ?? SheService.sheId;

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: Text(
                  item == null ? l10n.instructionSet_create : l10n.common_edit),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: nameController,
                        decoration: InputDecoration(
                          labelText: l10n.instructionSet_nameLabel,
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: descController,
                        decoration: InputDecoration(
                          labelText: l10n.instructionSet_descLabel,
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: contentController,
                        maxLines: 6,
                        minLines: 3,
                        decoration: InputDecoration(
                          labelText: l10n.instructionSet_contentLabel,
                          alignLabelWithHint: true,
                        ),
                      ),
                      if (item == null) ...[
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: ownerId,
                          decoration: InputDecoration(
                            labelText: l10n.instructionSet_ownerLabel,
                            isDense: true,
                          ),
                          items: [
                            DropdownMenuItem(
                              value: SheService.sheId,
                              child: Text(l10n.she_name),
                            ),
                            // She 自身也存在于 agents 表，需排除避免
                            // DropdownButton 出现重复 value 断言崩溃。
                            for (final agent in _agents)
                              if (agent.id != SheService.sheId)
                                DropdownMenuItem(
                                  value: agent.id,
                                  child: Text(
                                    agent.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              ownerId = value;
                              setDialogState(() {});
                            }
                          },
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            l10n.instructionSet_createHint,
                            style: Theme.of(dialogContext)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(dialogContext)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(l10n.common_cancel),
                ),
                FilledButton(
                  onPressed: () async {
                    final name = nameController.text.trim();
                    final content = contentController.text.trim();
                    if (name.isEmpty) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        SnackBar(content: Text(l10n.instructionSet_nameRequired)),
                      );
                      return;
                    }
                    if (content.isEmpty) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        SnackBar(
                            content: Text(l10n.instructionSet_contentRequired)),
                      );
                      return;
                    }
                    try {
                      if (item == null) {
                        await _service.create(
                          name: name,
                          description: descController.text,
                          content: content,
                          ownerAgentId: ownerId,
                        );
                      } else {
                        await _service.update(
                          id: item.id,
                          name: name,
                          description: descController.text,
                          content: content,
                        );
                      }
                      if (dialogContext.mounted) {
                        Navigator.pop(dialogContext, true);
                      }
                    } catch (e) {
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          SnackBar(
                              content: Text(
                                  l10n.instructionSet_saveFailed('$e'))),
                        );
                      }
                    }
                  },
                  child: Text(l10n.common_save),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved == true && mounted) {
      setState(() => _items = null);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(l10n.instructionSet_saved(nameController.text.trim())),
          ),
        );
      }
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
                icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
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
