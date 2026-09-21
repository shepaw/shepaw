import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/instruction_set.dart';
import '../models/remote_agent.dart';
import '../services/instruction_set_service.dart';
import '../services/local_database_service.dart';
import '../services/she_service.dart';
import '../widgets/form_bottom_bar.dart';

/// 指令集新建 / 编辑。
///
/// [embedded] 为 true 时就地编辑并自动保存（桌面主从、窄面板详情）。
/// 为 false 时是独立页：显式保存后 pop 回指令名称（储物袋文件预览）。
class InstructionSetEditorScreen extends StatefulWidget {
  /// 非空表示编辑该指令；为空表示新建。
  final InstructionSet? item;

  final bool embedded;

  /// 从当前对话打开时，主按钮是「填入当前对话」。
  final bool fillCurrentChat;

  /// 编辑态挂载 / 卸载。父级用它在执行前先落盘。
  final void Function(InstructionSetEditorScreenState state,
      {required bool active})? onEditorReady;

  /// 新建或更新已写入数据库。
  final void Function(InstructionSet saved, {required bool created})? onPersisted;

  /// 主按钮。为空则不显示（储物袋预览只编辑）。
  final Future<void> Function(InstructionSet item)? onRun;

  final ValueChanged<InstructionSet>? onDeleted;

  const InstructionSetEditorScreen({
    super.key,
    this.item,
    this.embedded = false,
    this.fillCurrentChat = false,
    this.onEditorReady,
    this.onPersisted,
    this.onRun,
    this.onDeleted,
  });

  @override
  State<InstructionSetEditorScreen> createState() =>
      InstructionSetEditorScreenState();
}

class InstructionSetEditorScreenState extends State<InstructionSetEditorScreen> {
  final _service = InstructionSetService.instance;
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  late final TextEditingController _contentController;

  List<RemoteAgent> _agents = const [];
  late String _ownerId;
  InstructionSet? _current;
  bool _saving = false;
  bool _queued = false;
  bool _showSaved = false;
  Timer? _debounce;

  static const _autosaveDelay = Duration(milliseconds: 500);

  bool get _isEditing => _current != null;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _current = item;
    _nameController = TextEditingController(text: item?.name ?? '');
    _descController = TextEditingController(text: item?.description ?? '');
    _contentController = TextEditingController(text: item?.content ?? '');
    _ownerId = item?.ownerAgentId ?? SheService.sheId;
    if (item == null) unawaited(_loadAgents());
    widget.onEditorReady?.call(this, active: true);
  }

  Future<void> _loadAgents() async {
    final agents = await LocalDatabaseService().getAllRemoteAgents();
    if (!mounted) return;
    setState(() => _agents = agents);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.onEditorReady?.call(this, active: false);
    _nameController.dispose();
    _descController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _onEdited() {
    _showSaved = false;
    if (widget.embedded) _schedule();
    setState(() {});
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(_autosaveDelay, () {
      unawaited(flush());
    });
  }

  /// 把当前输入写入数据库。名称或正文为空时不写。
  /// [notify] 为 true 时，空字段用提示条说明原因（主按钮按下）。
  Future<InstructionSet?> flush({bool notify = false}) async {
    _debounce?.cancel();
    if (_saving) {
      _queued = true;
      return _current;
    }
    final name = _nameController.text.trim();
    final content = _contentController.text.trim();
    if (name.isEmpty || content.isEmpty) {
      if (notify && mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(name.isEmpty
                ? l10n.instructionSet_nameRequired
                : l10n.instructionSet_contentRequired),
          ),
        );
      }
      return null;
    }
    final desc = _descController.text.trim();
    final current = _current;
    if (current != null &&
        current.name == name &&
        (current.description ?? '') == desc &&
        current.content == content) {
      return current;
    }
    return _persist(name: name, content: content);
  }

  Future<InstructionSet?> _persist({
    required String name,
    required String content,
  }) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _saving = true);
    final created = _current == null;
    try {
      final saved = created
          ? await _service.create(
              name: name,
              description: _descController.text,
              content: content,
              ownerAgentId: _ownerId,
              ownerAgentName: _ownerName(l10n),
            )
          : await _service.update(
              id: _current!.id,
              name: name,
              description: _descController.text,
              content: content,
            );
      widget.onPersisted?.call(saved, created: created);
      if (!mounted) return saved;
      setState(() {
        _current = saved;
        _saving = false;
        _showSaved = true;
      });
      return saved;
    } catch (e) {
      if (!mounted) return null;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.instructionSet_saveFailed('$e'))),
      );
      return null;
    } finally {
      if (_queued) {
        _queued = false;
        if (mounted && widget.embedded) _schedule();
      }
    }
  }

  String _ownerName(AppLocalizations l10n) {
    if (_ownerId == SheService.sheId) return l10n.she_name;
    for (final agent in _agents) {
      if (agent.id == _ownerId) return agent.name;
    }
    final snap = _current?.ownerAgentName ?? '';
    return snap.isNotEmpty ? snap : _ownerId;
  }

  String _formatTime(int millis) {
    final local = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    final now = DateTime.now();
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  Future<void> _saveExplicit() async {
    if (!_formKey.currentState!.validate()) return;
    final name = _nameController.text.trim();
    final saved = await _persist(
      name: name,
      content: _contentController.text.trim(),
    );
    if (saved != null && mounted && !widget.embedded) {
      Navigator.pop(context, saved.name);
    }
  }

  Future<void> _run() async {
    final saved = await flush(notify: true);
    if (saved == null || !mounted) return;
    await widget.onRun?.call(saved);
  }

  Future<void> _confirmDelete() async {
    final current = _current;
    if (current == null) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.instructionSet_deleteTitle),
        content: Text(l10n.instructionSet_deleteBody(current.name)),
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
    _debounce?.cancel();
    await _service.delete(current.id);
    if (!mounted) return;
    widget.onDeleted?.call(current);
    if (!widget.embedded) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _buildEmbedded(context);
    return _buildPage(context);
  }

  Widget _buildPage(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? l10n.common_edit : l10n.instructionSet_create),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _nameField(l10n, validate: true),
                    const SizedBox(height: 16),
                    _descField(l10n),
                    const SizedBox(height: 16),
                    _contentField(l10n, validate: true),
                    if (!_isEditing) ...[
                      const SizedBox(height: 16),
                      _ownerDropdown(l10n),
                      const SizedBox(height: 8),
                      Text(
                        l10n.instructionSet_createHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          FormBottomBar(
            child: FormPrimaryButton(
              onPressed: _saving ? null : _saveExplicit,
              isLoading: _saving,
              icon: Icons.save,
              label: l10n.common_save,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmbedded(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final ready = _nameController.text.trim().isNotEmpty &&
        _contentController.text.trim().isNotEmpty;
    final owner = _ownerName(l10n);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (_saving)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (_showSaved)
                Text(
                  l10n.common_savedStatus,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              const Spacer(),
              if (_isEditing)
                IconButton(
                  tooltip: l10n.common_delete,
                  icon: Icon(Icons.delete_outline, color: scheme.error),
                  onPressed: () => unawaited(_confirmDelete()),
                ),
              if (widget.onRun != null)
                FilledButton.icon(
                  onPressed:
                      (!ready || _saving) ? null : () => unawaited(_run()),
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: Text(widget.fillCurrentChat
                      ? l10n.instructionSet_fillCurrent
                      : l10n.instructionSet_run),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _nameField(l10n, validate: false),
                  const SizedBox(height: 12),
                  _descField(l10n),
                  const SizedBox(height: 12),
                  if (!_isEditing)
                    _ownerDropdown(l10n)
                  else
                    Text(
                      '${l10n.instructionSet_ownerLabel} $owner'
                      ' · ${l10n.instructionSet_updatedLabel} ${_formatTime(_current!.updatedAt)}',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  if (widget.fillCurrentChat || !_isEditing) ...[
                    const SizedBox(height: 8),
                    Text(
                      widget.fillCurrentChat
                          ? l10n.instructionSet_fillCurrentHint(owner)
                          : l10n.instructionSet_createHint,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _contentField(l10n, validate: false),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _nameField(AppLocalizations l10n, {required bool validate}) {
    return TextFormField(
      key: const ValueKey('instruction-name'),
      controller: _nameController,
      decoration: InputDecoration(
        labelText: l10n.instructionSet_nameLabel,
        border: const OutlineInputBorder(),
      ),
      validator: validate
          ? (v) => (v == null || v.trim().isEmpty)
              ? l10n.instructionSet_nameRequired
              : null
          : null,
      onChanged: widget.embedded ? (_) => _onEdited() : null,
    );
  }

  Widget _descField(AppLocalizations l10n) {
    return TextFormField(
      key: const ValueKey('instruction-desc'),
      controller: _descController,
      decoration: InputDecoration(
        labelText: l10n.instructionSet_descLabel,
        border: const OutlineInputBorder(),
        alignLabelWithHint: true,
      ),
      maxLines: 3,
      minLines: 2,
      onChanged: widget.embedded ? (_) => _onEdited() : null,
    );
  }

  Widget _contentField(AppLocalizations l10n, {required bool validate}) {
    return TextFormField(
      key: const ValueKey('instruction-content'),
      controller: _contentController,
      decoration: InputDecoration(
        labelText: l10n.instructionSet_contentLabel,
        border: const OutlineInputBorder(),
        alignLabelWithHint: true,
      ),
      maxLines: widget.embedded ? 16 : 12,
      minLines: widget.embedded ? 10 : 8,
      validator: validate
          ? (v) => (v == null || v.trim().isEmpty)
              ? l10n.instructionSet_contentRequired
              : null
          : null,
      onChanged: widget.embedded ? (_) => _onEdited() : null,
    );
  }

  Widget _ownerDropdown(AppLocalizations l10n) {
    return DropdownButtonFormField<String>(
      initialValue: _ownerId,
      decoration: InputDecoration(
        labelText: l10n.instructionSet_ownerLabel,
        border: const OutlineInputBorder(),
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
              child: Text(agent.name, overflow: TextOverflow.ellipsis),
            ),
      ],
      onChanged: (value) {
        if (value == null) return;
        setState(() => _ownerId = value);
        if (widget.embedded) _schedule();
      },
    );
  }
}
