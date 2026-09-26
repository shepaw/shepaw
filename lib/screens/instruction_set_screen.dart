import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/instruction_set.dart';
import '../service_locator.dart';
import '../services/chat_navigation_service.dart';
import '../services/chat_service.dart';
import '../services/composer_draft_service.dart';
import '../services/instruction_set_service.dart';
import '../services/jade_slip_service.dart';
import '../services/local_database_service.dart';
import '../services/local_user_identity.dart';
import '../services/she_service.dart';
import '../utils/layout_utils.dart';
import 'instruction_set_editor_screen.dart';

/// 指令集：查看 / 新建 / 编辑 / 删除 / 一键执行可复用的任务指令。
///
/// 桌面宽面板是左侧列表 + 右侧就地编辑。窄面板和手机点一条后在本页打开
/// 同一张编辑面。从聊天打开时主按钮把指令填入当前会话；从储物袋打开时
/// 执行会打开所属 Agent 的会话并预填正文。
class InstructionSetScreen extends StatefulWidget {
  /// 当前聊天上下文。非空表示从具体聊天内打开，执行指令时预填当前会话。
  final String? channelId;

  /// 当前聊天的 agent（DM 时有效；群聊为 null，走 [groupFamilyId]）。
  final String? agentId;

  /// 当前群聊的 group family id（群聊时有效）。
  final String? groupFamilyId;

  /// 嵌在桌面右栏时不显示外层返回。
  final bool embedded;

  const InstructionSetScreen({
    super.key,
    this.channelId,
    this.agentId,
    this.groupFamilyId,
    this.embedded = false,
  });

  @override
  State<InstructionSetScreen> createState() => _InstructionSetScreenState();
}

class _InstructionSetScreenState extends State<InstructionSetScreen> {
  final _service = InstructionSetService.instance;
  final _db = LocalDatabaseService();
  final _search = TextEditingController();

  List<InstructionSet>? _items;
  final Map<String, String> _ownerNames = {};
  String? _selectedId;
  bool _creating = false;
  String? _hoveredId;
  InstructionSetEditorScreenState? _editor;

  bool get _fillCurrent {
    final id = widget.channelId;
    return id != null && id.isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final items = await _service.list();
    final agents = await _db.getAllRemoteAgents();

    final names = <String, String>{};
    for (final agent in agents) {
      names[agent.id] = agent.name;
    }
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
      if (!_creating &&
          _selectedId != null &&
          items.every((s) => s.id != _selectedId)) {
        _selectedId = null;
      }
    });
  }

  AppLocalizations get _l10n => AppLocalizations.of(context);

  String _ownerLabel(String ownerId) {
    if (ownerId == SheService.sheId) return _l10n.she_name;
    return _ownerNames[ownerId] ?? ownerId;
  }

  bool _wideFor(BoxConstraints constraints) =>
      LayoutUtils.isDesktopLayout(context) && constraints.maxWidth >= 720;

  bool _matches(InstructionSet item) {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return item.name.toLowerCase().contains(q) ||
        (item.description ?? '').toLowerCase().contains(q) ||
        item.content.toLowerCase().contains(q);
  }

  void _startCreate() {
    unawaited(_editor?.flush());
    setState(() {
      _creating = true;
      _selectedId = null;
    });
  }

  void _select(InstructionSet item) {
    if (!_creating && item.id == _selectedId) return;
    unawaited(_editor?.flush());
    setState(() {
      _creating = false;
      _selectedId = item.id;
    });
  }

  void _closeDetail() {
    unawaited(_editor?.flush());
    setState(() {
      _creating = false;
      _selectedId = null;
    });
  }

  void _setEditor(InstructionSetEditorScreenState state, {required bool active}) {
    if (active) {
      _editor = state;
    } else if (identical(_editor, state)) {
      _editor = null;
    }
  }

  void _onPersisted(InstructionSet saved, {required bool created}) {
    setState(() {
      final rest = _items?.where((e) => e.id != saved.id).toList() ?? [];
      _items = [saved, ...rest];
      if (saved.ownerAgentName.isNotEmpty) {
        _ownerNames[saved.ownerAgentId] = saved.ownerAgentName;
      }
      if (created) {
        _creating = false;
        _selectedId = saved.id;
      }
    });
  }

  Future<void> _onDeleted(InstructionSet item) async {
    setState(() {
      _items = _items?.where((e) => e.id != item.id).toList();
      if (_selectedId == item.id) _selectedId = null;
      _creating = false;
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_l10n.instructionSet_deleted(item.name))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final items = _items;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = _wideFor(constraints);
        final selected = _selectedItem(items);
        final showingNarrowDetail =
            !wide && (_creating || selected != null);
        final hideOuterAppBar = widget.embedded && wide;
        return Scaffold(
          appBar: hideOuterAppBar
              ? null
              : AppBar(
                  title: Text(showingNarrowDetail
                      ? (_creating
                          ? l10n.instructionSet_create
                          : (selected?.name ?? l10n.instructionSet_title))
                      : l10n.instructionSet_title),
                  elevation: widget.embedded ? 0 : null,
                  automaticallyImplyLeading:
                      !widget.embedded && !showingNarrowDetail,
                  leading: showingNarrowDetail
                      ? BackButton(onPressed: _closeDetail)
                      : null,
                  actions: [
                    if (!showingNarrowDetail)
                      IconButton(
                        tooltip: l10n.instructionSet_create,
                        icon: const Icon(Icons.add),
                        onPressed: _startCreate,
                      ),
                  ],
                ),
          body: items == null
              ? const Center(child: CircularProgressIndicator())
              : wide
                  ? Row(
                      children: [
                        SizedBox(
                          width: 300,
                          child: _buildListPane(
                            l10n,
                            items,
                            wide: true,
                            showHeader: hideOuterAppBar,
                          ),
                        ),
                        VerticalDivider(
                          width: 1,
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        Expanded(child: _buildDetail(l10n, selected)),
                      ],
                    )
                  : showingNarrowDetail
                      ? _buildDetail(l10n, selected)
                      : _buildListPane(l10n, items, wide: false, showHeader: false),
        );
      },
    );
  }

  InstructionSet? _selectedItem(List<InstructionSet>? items) {
    if (items == null || _selectedId == null) return null;
    for (final item in items) {
      if (item.id == _selectedId) return item;
    }
    return null;
  }

  Widget _buildDetail(AppLocalizations l10n, InstructionSet? selected) {
    if (!_creating && selected == null) {
      final scheme = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.playlist_add_check_outlined,
                size: 40, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              l10n.instructionSet_pickHint,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
    }
    return InstructionSetEditorScreen(
      key: ValueKey(_creating ? 'creating' : selected!.id),
      item: _creating ? null : selected,
      embedded: true,
      fillCurrentChat: _fillCurrent,
      onEditorReady: _setEditor,
      onPersisted: _onPersisted,
      onRun: _runInstruction,
      onDeleted: (item) => unawaited(_onDeleted(item)),
    );
  }

  Widget _buildListPane(
    AppLocalizations l10n,
    List<InstructionSet> items, {
    required bool wide,
    required bool showHeader,
  }) {
    final theme = Theme.of(context);
    final visible = items.where(_matches).toList();
    final groups = <String, List<InstructionSet>>{};
    final owners = <String>[];
    for (final item in visible) {
      groups.putIfAbsent(item.ownerAgentId, () {
        owners.add(item.ownerAgentId);
        return [];
      }).add(item);
    }
    final showHeaders = owners.length > 1;
    final entries = <(String?, InstructionSet?)>[
      for (final owner in owners) ...[
        if (showHeaders) (owner, null),
        for (final item in groups[owner]!) (null, item),
      ],
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader)
          SizedBox(
            height: kToolbarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.instructionSet_title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.instructionSet_create,
                    icon: const Icon(Icons.add),
                    onPressed: _startCreate,
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              hintText: l10n.common_search,
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? _buildEmpty(l10n, searching: _search.text.trim().isNotEmpty)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final header = entries[index].$1;
                    if (header != null) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                        child: Text(
                          _ownerLabel(header),
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      );
                    }
                    final item = entries[index].$2!;
                    return _InstructionRow(
                      item: item,
                      subtitle: item.description?.trim().isNotEmpty == true
                          ? item.description!.trim()
                          : null,
                      selected: item.id == _selectedId && !_creating,
                      showRun: wide &&
                          (_hoveredId == item.id || item.id == _selectedId),
                      runLabel: _fillCurrent
                          ? l10n.instructionSet_fillCurrent
                          : l10n.instructionSet_run,
                      onHover: (hover) => setState(() {
                        _hoveredId = hover ? item.id : null;
                      }),
                      onTap: () => _select(item),
                      onRun: () => unawaited(_runFromRow(item)),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildEmpty(AppLocalizations l10n, {required bool searching}) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              searching
                  ? Icons.search_off
                  : Icons.playlist_add_check_outlined,
              size: 48,
              color: scheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              searching ? l10n.instructionSet_noMatch : l10n.instructionSet_empty,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runFromRow(InstructionSet item) async {
    if (item.id == _selectedId && _editor != null) {
      final latest = await _editor!.flush(notify: true);
      if (latest == null) return;
      await _runInstruction(latest);
      return;
    }
    await _runInstruction(item);
  }

  Future<void> _runInstruction(InstructionSet item) async {
    final l10n = _l10n;
    final chatService = getIt<ChatService>();
    const userId = LocalUserIdentity.id;
    final ownerId = item.ownerAgentId;
    // 内置「沉淀指令」的产出是一条指令，只落指令集；其余指令用玉简跟踪进度。
    final slip = InstructionSetService.isSystemInstruction(item)
        ? null
        : await JadeSlipService.instance.create(
            title: item.name,
            goal: item.content,
            assigneeAgentId: ownerId,
            assigneeAgentName: item.ownerAgentName,
            sourceInstructionId: item.id,
          );
    final tracked = slip == null
        ? InstructionSetService.systemInstructionRunPrompt(item.content)
        : '这次执行记在玉简「${slip.title}」（id=${slip.id}）。\n${item.content}';

    final currentChannelId = widget.channelId;
    if (currentChannelId != null && currentChannelId.isNotEmpty) {
      getIt<ComposerDraftService>().setDraft(
        currentChannelId,
        tracked,
        agentId: widget.agentId,
        groupFamilyId: widget.groupFamilyId,
        instructionName: item.name,
      );
      if (mounted) Navigator.pop(context);
      return;
    }

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
      tracked,
      agentId: ownerId,
      instructionName: item.name,
    );

    await ChatNavigationService.instance.openChannel(
      channelId: channelId,
      agentId: ownerId,
      agentName: ownerName,
      agentAvatar: ownerAvatar,
    );
  }
}

class _InstructionRow extends StatelessWidget {
  const _InstructionRow({
    required this.item,
    required this.subtitle,
    required this.selected,
    required this.showRun,
    required this.runLabel,
    required this.onHover,
    required this.onTap,
    required this.onRun,
  });

  final InstructionSet item;
  final String? subtitle;
  final bool selected;
  final bool showRun;
  final String runLabel;
  final ValueChanged<bool> onHover;
  final VoidCallback onTap;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Material(
          color: selected
              ? scheme.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 36,
                  margin: const EdgeInsets.only(left: 4),
                  decoration: BoxDecoration(
                    color: selected ? scheme.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (showRun)
                  IconButton(
                    tooltip: runLabel,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.play_arrow_rounded,
                      color: selected ? scheme.primary : scheme.outline,
                    ),
                    onPressed: onRun,
                  )
                else
                  const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
