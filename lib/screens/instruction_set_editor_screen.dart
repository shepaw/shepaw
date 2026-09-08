import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/instruction_set.dart';
import '../models/remote_agent.dart';
import '../services/instruction_set_service.dart';
import '../services/local_database_service.dart';
import '../services/she_service.dart';
import '../widgets/form_bottom_bar.dart';

/// 指令集新建 / 编辑页。
///
/// 保存成功后 pop 回指令名称，调用方据此刷新列表。
class InstructionSetEditorScreen extends StatefulWidget {
  /// 非空表示编辑该指令；为空表示新建。
  final InstructionSet? item;

  const InstructionSetEditorScreen({super.key, this.item});

  @override
  State<InstructionSetEditorScreen> createState() =>
      _InstructionSetEditorScreenState();
}

class _InstructionSetEditorScreenState
    extends State<InstructionSetEditorScreen> {
  final _service = InstructionSetService.instance;
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  late final TextEditingController _contentController;

  List<RemoteAgent> _agents = const [];
  late String _ownerId;
  bool _saving = false;

  bool get _isEditing => widget.item != null;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _nameController = TextEditingController(text: item?.name ?? '');
    _descController = TextEditingController(text: item?.description ?? '');
    _contentController = TextEditingController(text: item?.content ?? '');
    _ownerId = item?.ownerAgentId ?? SheService.sheId;
    if (item == null) unawaited(_loadAgents());
  }

  Future<void> _loadAgents() async {
    final agents = await LocalDatabaseService().getAllRemoteAgents();
    if (!mounted) return;
    setState(() => _agents = agents);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final l10n = AppLocalizations.of(context);
    final name = _nameController.text.trim();
    final content = _contentController.text.trim();

    setState(() => _saving = true);
    try {
      if (_isEditing) {
        await _service.update(
          id: widget.item!.id,
          name: name,
          description: _descController.text,
          content: content,
        );
      } else {
        await _service.create(
          name: name,
          description: _descController.text,
          content: content,
          ownerAgentId: _ownerId,
        );
      }
      if (mounted) Navigator.pop(context, name);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.instructionSet_saveFailed('$e'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
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
                    TextFormField(
                      controller: _nameController,
                      decoration: InputDecoration(
                        labelText: l10n.instructionSet_nameLabel,
                        border: const OutlineInputBorder(),
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? l10n.instructionSet_nameRequired
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _descController,
                      decoration: InputDecoration(
                        labelText: l10n.instructionSet_descLabel,
                        border: const OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                      maxLines: 3,
                      minLines: 2,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _contentController,
                      decoration: InputDecoration(
                        labelText: l10n.instructionSet_contentLabel,
                        border: const OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                      maxLines: 12,
                      minLines: 8,
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? l10n.instructionSet_contentRequired
                          : null,
                    ),
                    if (!_isEditing) ...[
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
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
                                child: Text(
                                  agent.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                        ],
                        onChanged: (value) {
                          if (value != null) setState(() => _ownerId = value);
                        },
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.instructionSet_createHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          FormBottomBar(
            child: FormPrimaryButton(
              onPressed: _saving ? null : _save,
              isLoading: _saving,
              icon: Icons.save,
              label: l10n.common_save,
            ),
          ),
        ],
      ),
    );
  }
}
