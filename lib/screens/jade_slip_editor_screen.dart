import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import '../models/jade_slip.dart';
import '../models/remote_agent.dart';
import '../models/store_attachment_ref.dart';
import '../services/jade_slip_service.dart';
import '../services/local_database_service.dart';
import '../services/local_user_identity.dart';
import '../services/she_service.dart';
import '../services/store_open_service.dart';
import '../theme/app_theme.dart';
import '../widgets/chat/storage_file_picker_screen.dart';
import 'jade_slip_dispatch.dart';
import 'storage_shared.dart';

/// 玉简编辑：标题、清单勾选、备注、负责人、截止日期。
class JadeSlipEditorScreen extends StatefulWidget {
  final String slipId;
  final bool embedded;
  final bool focusChecklist;
  final VoidCallback? onChanged;

  const JadeSlipEditorScreen({
    super.key,
    required this.slipId,
    this.embedded = false,
    this.focusChecklist = false,
    this.onChanged,
  });

  @override
  State<JadeSlipEditorScreen> createState() => _JadeSlipEditorScreenState();
}

class _JadeSlipEditorScreenState extends State<JadeSlipEditorScreen> {
  final _service = JadeSlipService.instance;
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _item = TextEditingController();
  final _itemFocus = FocusNode();
  final _comment = TextEditingController();
  final _runKey = GlobalKey();

  JadeSlip? _slip;
  List<RemoteAgent> _agents = const [];
  bool _saving = false;
  bool _dirty = false;
  bool _closed = false;
  bool _didFocusChecklist = false;
  Timer? _textDebounce;
  StreamSubscription<void>? _sub;

  static const _btnRadius = BorderRadius.all(Radius.circular(10));

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_loadAgents());
    _sub = _service.changes.listen((_) {
      if (!_dirty) unawaited(_reloadSilent());
    });
  }

  @override
  void dispose() {
    _textDebounce?.cancel();
    final slip = _slip;
    if (!_closed && _dirty && slip != null) {
      final title = _title.text.trim();
      if (title.isNotEmpty) {
        unawaited(_service.update(slip.copyWith(title: title, body: _body.text)));
      }
    }
    _sub?.cancel();
    _title.dispose();
    _body.dispose();
    _item.dispose();
    _itemFocus.dispose();
    _comment.dispose();
    super.dispose();
  }

  Future<void> _loadAgents() async {
    final agents = await LocalDatabaseService().getAllRemoteAgents();
    if (mounted) setState(() => _agents = agents);
  }

  Future<void> _load() async {
    final slip = await _service.getById(widget.slipId);
    if (!mounted) return;
    if (slip == null) {
      if (!widget.embedded) Navigator.pop(context);
      return;
    }
    _title.text = slip.title;
    _body.text = slip.body;
    setState(() {
      _slip = slip;
      _dirty = false;
    });
    _maybeFocusChecklist();
  }

  void _maybeFocusChecklist() {
    if (_didFocusChecklist || !widget.focusChecklist) return;
    _didFocusChecklist = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _itemFocus.requestFocus();
    });
  }

  void _onTextChanged() {
    setState(() => _dirty = true);
    _textDebounce?.cancel();
    _textDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_flush(notifyIfEmpty: false));
    });
  }

  Future<void> _reloadSilent() async {
    final slip = await _service.getById(widget.slipId);
    if (!mounted || slip == null || _dirty) return;
    if (_title.text != slip.title) _title.text = slip.title;
    if (_body.text != slip.body) _body.text = slip.body;
    setState(() => _slip = slip);
  }

  Future<void> _persist(JadeSlip next) async {
    setState(() => _saving = true);
    try {
      final saved = await _service.update(next);
      if (!mounted) return;
      setState(() {
        _slip = saved;
        _dirty = false;
        _saving = false;
      });
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text(AppLocalizations.of(context).jadeSlip_saveFailed('$e'))),
      );
    }
  }

  Future<bool> _flush({bool notifyIfEmpty = true}) async {
    _textDebounce?.cancel();
    final slip = _slip;
    if (slip == null) return true;
    final title = _title.text.trim();
    if (title.isEmpty) {
      if (notifyIfEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(AppLocalizations.of(context).jadeSlip_titleRequired)),
        );
      }
      return false;
    }
    if (!_dirty && title == slip.title && _body.text == slip.body) return true;
    await _persist(slip.copyWith(title: title, body: _body.text));
    return true;
  }

  Future<void> _addItem() async {
    final text = _item.text.trim();
    if (text.isEmpty || _slip == null) return;
    _item.clear();
    await _flush();
    await _service.addItem(id: widget.slipId, text: text);
    widget.onChanged?.call();
    await _load();
  }

  Future<void> _addComment() async {
    final text = _comment.text.trim();
    if (text.isEmpty || _slip == null) return;
    final l10n = AppLocalizations.of(context);
    _comment.clear();
    await _flush();
    await _service.addComment(
      id: widget.slipId,
      text: text,
      authorId: LocalUserIdentity.id,
      authorName: l10n.jadeSlip_commentMine,
    );
    widget.onChanged?.call();
    await _load();
  }

  Future<void> _removeComment(String commentId) async {
    final slip = _slip;
    if (slip == null) return;
    await _flush();
    setState(() {
      _slip = slip.copyWith(
        comments: [for (final c in slip.comments) if (c.id != commentId) c],
      );
    });
    await _service.removeComment(id: widget.slipId, commentId: commentId);
    widget.onChanged?.call();
    await _load();
  }

  Future<void> _renameItem(String itemId, String text) async {
    final slip = _slip;
    if (slip == null) return;
    await _flush();
    setState(() {
      _slip = slip.copyWith(
        items: [
          for (final item in slip.items)
            if (item.id == itemId) item.copyWith(text: text) else item,
        ],
      );
    });
    await _service.updateItemText(id: widget.slipId, itemId: itemId, text: text);
    widget.onChanged?.call();
    await _load();
  }

  Future<void> _removeItem(String itemId) async {
    final slip = _slip;
    if (slip == null) return;
    await _flush();
    setState(() {
      _slip = slip.copyWith(
        items: [for (final item in slip.items) if (item.id != itemId) item],
      );
    });
    await _service.removeItem(id: widget.slipId, itemId: itemId);
    widget.onChanged?.call();
    await _load();
  }

  Future<void> _removeAttachment(String attachmentId) async {
    final slip = _slip;
    if (slip == null) return;
    await _flush();
    setState(() {
      _slip = slip.copyWith(
        attachments: [
          for (final a in slip.attachments)
            if (a.id != attachmentId) a,
        ],
      );
    });
    await _service.removeAttachment(id: widget.slipId, attachmentId: attachmentId);
    widget.onChanged?.call();
    await _load();
  }

  Future<void> _addLocalAttachments() async {
    final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (picked == null || picked.files.isEmpty || !mounted) return;
    await _flush();
    setState(() => _saving = true);
    try {
      for (final item in picked.files) {
        final localPath = item.path;
        if (localPath == null) continue;
        final file = File(localPath);
        if (!await file.exists()) continue;
        await _service.addAttachment(
          id: widget.slipId,
          file: file,
          displayName: p.basename(localPath),
        );
      }
      widget.onChanged?.call();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).jadeSlip_attachmentFailed('$e'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addStoreAttachments() async {
    final refs = await Navigator.of(context).push<List<StoreAttachmentRef>>(
      MaterialPageRoute(
        builder: (_) => const StorageFilePickerScreen(maxSelection: 20),
      ),
    );
    if (refs == null || refs.isEmpty || !mounted) return;
    await _flush();
    setState(() => _saving = true);
    try {
      for (final ref in refs) {
        final file = await ref.resolveLocalFile();
        if (file == null) continue;
        await _service.addAttachment(
          id: widget.slipId,
          file: file,
          displayName: ref.displayName,
        );
      }
      widget.onChanged?.call();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).jadeSlip_attachmentFailed('$e'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final slip = _slip;
    if (slip == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final body = Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            children: [
              Row(
                children: [
                  if (_saving)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (!_dirty)
                    Text(
                      l10n.common_savedStatus,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  const Spacer(),
                  FilledButton.icon(
                    key: _runKey,
                    onPressed: _saving ? null : () => unawaited(_handOff(slip)),
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    label: Text(l10n.jadeSlip_run),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      shape: const RoundedRectangleBorder(
                        borderRadius: _btnRadius,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.common_delete,
                    icon: Icon(Icons.delete_outline,
                        color: scheme.onSurfaceVariant),
                    onPressed: () => unawaited(_confirmDelete(slip)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _title,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
                decoration: InputDecoration(
                  hintText: l10n.jadeSlip_titleHint,
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                onChanged: (_) => _onTextChanged(),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _PriorityPill(
                    value: slip.priority,
                    label: _priorityLabel(l10n, slip.priority),
                    onChanged: (v) =>
                        unawaited(_persist(slip.copyWith(priority: v))),
                    labelOf: (p) => _priorityLabel(l10n, p),
                  ),
                  _MetaPill(
                    icon: Icons.event_outlined,
                    label: slip.dueAtMs == null
                        ? l10n.jadeSlip_dueNone
                        : _fmtDay(slip.dueAtMs!),
                    active: slip.dueAtMs != null,
                    onTap: () => unawaited(_pickDue(slip)),
                    onClear: slip.dueAtMs == null
                        ? null
                        : () => unawaited(_persist(slip.copyWith(clearDue: true))),
                  ),
                  _AssigneePill(
                    label: slip.assigneeAgentName.isEmpty
                        ? l10n.jadeSlip_assigneeNone
                        : slip.assigneeAgentName,
                    active: slip.assigneeAgentName.isNotEmpty,
                    noneLabel: l10n.jadeSlip_assigneeNone,
                    sheLabel: l10n.she_name,
                    agents: _agents,
                    onSelected: (id, name) => unawaited(_persist(slip.copyWith(
                      assigneeAgentId: id,
                      assigneeAgentName: name,
                    ))),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              _SectionLabel(
                label: l10n.jadeSlip_checklist,
                trailing: slip.itemCount == 0
                    ? null
                    : l10n.jadeSlip_progress(slip.doneCount, slip.itemCount),
              ),
              const SizedBox(height: 6),
              for (final item in slip.items)
                _ChecklistRow(
                  key: ValueKey(item.id),
                  item: item,
                  onChanged: (v) => unawaited(_service.setItemDone(
                    id: slip.id,
                    itemId: item.id,
                    done: v,
                  )),
                  onDelete: () => unawaited(_removeItem(item.id)),
                  onRename: (text) => unawaited(_renameItem(item.id, text)),
                ),
              _AddItemRow(
                controller: _item,
                focusNode: _itemFocus,
                hint: l10n.jadeSlip_itemHint,
                onSubmit: () => unawaited(_addItem()),
              ),
              const SizedBox(height: 28),
              _SectionLabel(
                label: l10n.jadeSlip_attachments,
                trailing: slip.attachments.isEmpty
                    ? null
                    : l10n.jadeSlip_attachmentCount(slip.attachments.length),
              ),
              const SizedBox(height: 6),
              for (final att in slip.attachments)
                _AttachmentRow(
                  attachment: att,
                  onOpen: () => unawaited(
                    StoreOpenService.instance.openStoreUri(
                      context,
                      att.uriFor(slip.deviceId),
                    ),
                  ),
                  onDelete: () => unawaited(_removeAttachment(att.id)),
                ),
              _AddAttachmentRow(
                hint: l10n.jadeSlip_addAttachment,
                localLabel: l10n.jadeSlip_attachLocal,
                storeLabel: l10n.jadeSlip_attachStore,
                enabled: !_saving,
                onLocal: () => unawaited(_addLocalAttachments()),
                onStore: () => unawaited(_addStoreAttachments()),
              ),
              const SizedBox(height: 28),
              _SectionLabel(label: l10n.jadeSlip_notes),
              const SizedBox(height: 8),
              TextField(
                controller: _body,
                minLines: 5,
                maxLines: 14,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                decoration: InputDecoration(
                  hintText: l10n.jadeSlip_notesHint,
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                        color: scheme.primary.withValues(alpha: 0.4)),
                  ),
                  contentPadding: const EdgeInsets.all(14),
                ),
                onChanged: (_) => _onTextChanged(),
              ),
              const SizedBox(height: 28),
              _SectionLabel(
                label: l10n.jadeSlip_comments,
                trailing: slip.comments.isEmpty
                    ? null
                    : '${slip.comments.length}',
              ),
              const SizedBox(height: 6),
              if (slip.comments.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    l10n.jadeSlip_commentEmpty,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                for (final comment in slip.comments)
                  _CommentRow(
                    comment: comment,
                    onDelete: comment.authorId == LocalUserIdentity.id
                        ? () => unawaited(_removeComment(comment.id))
                        : null,
                  ),
              _AddItemRow(
                controller: _comment,
                focusNode: null,
                hint: l10n.jadeSlip_commentHint,
                onSubmit: () => unawaited(_addComment()),
              ),
            ],
          ),
        ),
      ],
    );

    if (widget.embedded) return body;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (!await _flush() || !mounted) return;
        navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.jadeSlip_title),
        ),
        body: body,
      ),
    );
  }

  Future<void> _confirmDelete(JadeSlip slip) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.jadeSlip_deleteTitle),
        content: Text(l10n.jadeSlip_deleteBody(slip.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.common_delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _textDebounce?.cancel();
    _closed = true;
    _dirty = false;
    await _service.delete(slip.id);
    widget.onChanged?.call();
    if (mounted && !widget.embedded) Navigator.pop(context);
  }

  Future<void> _handOff(JadeSlip slip) async {
    if (!await _flush()) return;
    final latest = await _service.getById(widget.slipId);
    if (latest == null || !mounted) return;
    if (latest.assigneeAgentId.trim().isEmpty) {
      final agentId = await _pickRunAgent();
      if (agentId == null || !mounted) return;
      await dispatchJadeSlip(context, latest, preferredAgentId: agentId);
      return;
    }
    await dispatchJadeSlip(context, latest);
  }

  Future<String?> _pickRunAgent() async {
    final l10n = AppLocalizations.of(context);
    final box = _runKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) return null;
    final rect = Rect.fromPoints(
      box.localToGlobal(Offset.zero, ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    );
    return showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: [
        PopupMenuItem(value: SheService.sheId, child: Text(l10n.she_name)),
        for (final agent in _agents)
          if (agent.id != SheService.sheId)
            PopupMenuItem(value: agent.id, child: Text(agent.name)),
      ],
    );
  }

  Future<void> _pickDue(JadeSlip slip) async {
    final initial = slip.dueAtMs == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(slip.dueAtMs!);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    await _persist(slip.copyWith(
      dueAtMs: DateTime(picked.year, picked.month, picked.day, 18)
          .millisecondsSinceEpoch,
    ));
  }

  String _priorityLabel(AppLocalizations l10n, JadeSlipPriority p) =>
      switch (p) {
        JadeSlipPriority.none => l10n.jadeSlip_priorityNone,
        JadeSlipPriority.low => l10n.jadeSlip_priorityLow,
        JadeSlipPriority.medium => l10n.jadeSlip_priorityMedium,
        JadeSlipPriority.high => l10n.jadeSlip_priorityHigh,
      };
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, this.trailing});

  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
            letterSpacing: 0.2,
          ),
        ),
        if (trailing != null) ...[
          const Spacer(),
          Text(
            trailing!,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.onClear,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = active ? scheme.onSurface : scheme.onSurfaceVariant;
    return Material(
      color: active
          ? AppColors.primary.withValues(alpha: 0.08)
          : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: active ? AppColors.primary : fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: fg,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              if (onClear != null)
                InkWell(
                  onTap: onClear,
                  customBorder: const CircleBorder(),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(Icons.close, size: 14, color: scheme.onSurfaceVariant),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Icon(Icons.expand_more, size: 16, color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssigneePill extends StatelessWidget {
  const _AssigneePill({
    required this.label,
    required this.active,
    required this.noneLabel,
    required this.sheLabel,
    required this.agents,
    required this.onSelected,
  });

  final String label;
  final bool active;
  final String noneLabel;
  final String sheLabel;
  final List<RemoteAgent> agents;
  final void Function(String id, String name) onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = active ? scheme.onSurface : scheme.onSurfaceVariant;
    return PopupMenuButton<(String, String)>(
      tooltip: label,
      onSelected: (picked) => onSelected(picked.$1, picked.$2),
      itemBuilder: (ctx) => [
        PopupMenuItem(value: ('', ''), child: Text(noneLabel)),
        PopupMenuItem(
          value: (SheService.sheId, sheLabel),
          child: Text(sheLabel),
        ),
        for (final agent in agents)
          if (agent.id != SheService.sheId)
            PopupMenuItem(
              value: (agent.id, agent.name),
              child: Text(agent.name),
            ),
      ],
      child: Material(
        color: active
            ? AppColors.primary.withValues(alpha: 0.08)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.smart_toy_outlined,
                size: 16,
                color: active ? AppColors.primary : fg,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: fg,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              Icon(Icons.expand_more, size: 16, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _PriorityPill extends StatelessWidget {
  const _PriorityPill({
    required this.value,
    required this.label,
    required this.onChanged,
    required this.labelOf,
  });

  final JadeSlipPriority value;
  final String label;
  final ValueChanged<JadeSlipPriority> onChanged;
  final String Function(JadeSlipPriority) labelOf;

  Color _color() => switch (value) {
        JadeSlipPriority.high => const Color(0xFFE24C4C),
        JadeSlipPriority.medium => AppColors.primary,
        JadeSlipPriority.low => const Color(0xFF5B8DEF),
        JadeSlipPriority.none => AppColors.textSecondary,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = _color();
    final active = value != JadeSlipPriority.none;
    return PopupMenuButton<JadeSlipPriority>(
      tooltip: label,
      onSelected: onChanged,
      itemBuilder: (ctx) => [
        for (final p in JadeSlipPriority.values)
          PopupMenuItem(
            value: p,
            child: Text(labelOf(p)),
          ),
      ],
      child: Material(
        color: active
            ? color.withValues(alpha: 0.12)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.flag_outlined, size: 16, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: active ? color : scheme.onSurfaceVariant,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              Icon(Icons.expand_more, size: 16, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// 清单项：勾选、行内改字、更多操作（编辑 / 删除）。
class _ChecklistRow extends StatefulWidget {
  const _ChecklistRow({
    super.key,
    required this.item,
    required this.onChanged,
    required this.onDelete,
    required this.onRename,
  });

  final JadeSlipItem item;
  final ValueChanged<bool> onChanged;
  final VoidCallback onDelete;
  final ValueChanged<String> onRename;

  @override
  State<_ChecklistRow> createState() => _ChecklistRowState();
}

class _ChecklistRowState extends State<_ChecklistRow> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _editing = false;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _beginEdit() {
    _controller.text = widget.item.text;
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty && text != widget.item.text) {
      widget.onRename(text);
    }
    if (mounted) setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final item = widget.item;
    return Dismissible(
      key: ValueKey('item-${item.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => widget.onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
      ),
      child: InkWell(
        onTap: _editing ? null : () => widget.onChanged(!item.done),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: item.done,
                  onChanged: (v) => widget.onChanged(v ?? false),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  side: BorderSide(color: scheme.outline, width: 1.4),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _editing
                    ? TextField(
                        controller: _controller,
                        focusNode: _focus,
                        style: theme.textTheme.bodyLarge,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 8),
                        ),
                        onSubmitted: (_) => _submit(),
                      )
                    : Text(
                        item.text,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          decoration:
                              item.done ? TextDecoration.lineThrough : null,
                          color: item.done
                              ? scheme.onSurfaceVariant
                              : scheme.onSurface,
                        ),
                      ),
              ),
              if (_editing)
                IconButton(
                  tooltip: l10n.common_save,
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: _submit,
                  icon: Icon(Icons.check, color: scheme.primary),
                )
              else
                PopupMenuButton<String>(
                  tooltip: l10n.common_more,
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  icon: Icon(Icons.more_vert, color: scheme.onSurfaceVariant),
                  onSelected: (v) {
                    if (v == 'edit') _beginEdit();
                    if (v == 'delete') widget.onDelete();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: Text(l10n.common_edit),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(l10n.common_delete),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddItemRow extends StatelessWidget {
  const _AddItemRow({
    required this.controller,
    required this.hint,
    required this.onSubmit,
    this.focusNode,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(Icons.add, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              textInputAction: TextInputAction.done,
              style: theme.textTheme.bodyLarge,
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
              onSubmitted: (_) => onSubmit(),
            ),
          ),
        ],
      ),
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({required this.comment, this.onDelete});

  final JadeSlipComment comment;

  /// 只允许删自己写的评论，避免误删 Agent 的过程记录。
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.comment_outlined, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (comment.createdAt > 0) ...[
                      const SizedBox(width: 6),
                      Text(
                        _fmtStamp(comment.createdAt),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  comment.text,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
              ],
            ),
          ),
          if (onDelete != null)
            IconButton(
              tooltip: l10n.common_delete,
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: onDelete,
              icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

class _AttachmentRow extends StatelessWidget {
  const _AttachmentRow({
    required this.attachment,
    required this.onOpen,
    required this.onDelete,
  });

  final JadeSlipAttachment attachment;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final size = attachment.sizeBytes > 0
        ? fmtStorageBytes(attachment.sizeBytes)
        : null;
    return Dismissible(
      key: ValueKey('att-${attachment.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
      ),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(Icons.attach_file, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      attachment.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge,
                    ),
                    if (size != null)
                      Text(
                        size,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: l10n.common_delete,
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: onDelete,
                icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddAttachmentRow extends StatelessWidget {
  const _AddAttachmentRow({
    required this.hint,
    required this.localLabel,
    required this.storeLabel,
    required this.enabled,
    required this.onLocal,
    required this.onStore,
  });

  final String hint;
  final String localLabel;
  final String storeLabel;
  final bool enabled;
  final VoidCallback onLocal;
  final VoidCallback onStore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return PopupMenuButton<String>(
      enabled: enabled,
      tooltip: hint,
      onSelected: (v) {
        if (v == 'local') onLocal();
        if (v == 'store') onStore();
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(value: 'local', child: Text(localLabel)),
        PopupMenuItem(value: 'store', child: Text(storeLabel)),
      ],
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            Icon(Icons.add, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                hint,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _fmtDay(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

String _fmtStamp(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  return '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} $hh:$mm';
}
