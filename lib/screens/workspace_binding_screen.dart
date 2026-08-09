import 'package:flutter/material.dart';

import '../storage/workspace_binding_service.dart';

/// 绑定 / 解绑 workspaces/<id> 到 runtime/<owner>/workspace.md。
class WorkspaceBindingScreen extends StatefulWidget {
  const WorkspaceBindingScreen({
    super.key,
    required this.ownerId,
    required this.displayName,
  });

  final String ownerId;
  final String displayName;

  @override
  State<WorkspaceBindingScreen> createState() => _WorkspaceBindingScreenState();
}

class _WorkspaceBindingScreenState extends State<WorkspaceBindingScreen> {
  bool _loading = true;
  bool _saving = false;
  List<String> _available = const [];
  final Set<String> _selected = {};
  String? _error;

  bool get _zh =>
      Localizations.localeOf(context).languageCode.startsWith('zh');

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
      final available =
          await WorkspaceBindingService.instance.listAvailableWorkspaceIds();
      final bound =
          await WorkspaceBindingService.instance.loadBoundIds(widget.ownerId);
      if (!mounted) return;
      setState(() {
        _available = available;
        _selected
          ..clear()
          ..addAll(bound);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await WorkspaceBindingService.instance
          .saveBoundIds(widget.ownerId, _selected.toList());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_zh ? '已保存工作区绑定' : 'Workspace bindings saved'),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_zh ? "保存失败" : "Save failed"}: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_zh
            ? '${widget.displayName} · 工作区'
            : '${widget.displayName} · Workspaces'),
        actions: [
          TextButton(
            onPressed: _saving || _loading ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_zh ? '保存' : 'Save'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      _zh
                          ? '勾选要绑定到此 Agent/群的工作区（store://workspaces/…）。绑定写入 runtime/workspace.md，并更新 ContextBundle。'
                          : 'Select workspaces to bind (store://workspaces/…). Saved to runtime/workspace.md and ContextBundle.',
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_available.isEmpty)
                      Text(
                        _zh
                            ? '本机尚无 workspaces/ 目录。可用储物袋写入后再绑定。'
                            : 'No local workspaces yet. Write into the pouch first.',
                        style: TextStyle(color: colorScheme.onSurfaceVariant),
                      )
                    else
                      ..._available.map((id) {
                        final checked = _selected.contains(id);
                        return CheckboxListTile(
                          value: checked,
                          title: Text(id),
                          subtitle: Text('workspaces/$id'),
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _selected.add(id);
                              } else {
                                _selected.remove(id);
                              }
                            });
                          },
                        );
                      }),
                  ],
                ),
    );
  }
}
