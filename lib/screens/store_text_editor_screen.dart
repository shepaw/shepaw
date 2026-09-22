import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import '../widgets/discard_changes_scope.dart';
import '../storage/local_store.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import '../storage/store_uri_reader.dart';

/// 储物袋里的文本文件编辑器：读全文 → 编辑 → 覆盖写回同路径。
///
/// 只接白名单内的文本文件（见 [StoreTextEditorScreen] 调用方判定），
/// 覆盖写由 [LocalStore] 自动把旧内容归档进 `.versions`。
class StoreTextEditorScreen extends StatefulWidget {
  const StoreTextEditorScreen({
    super.key,
    required this.space,
    required this.deviceId,
    required this.relPath,
  });

  final String space;
  final String deviceId;
  final String relPath;

  @override
  State<StoreTextEditorScreen> createState() => _StoreTextEditorScreenState();
}

class _StoreTextEditorScreenState extends State<StoreTextEditorScreen> {
  final _controller = TextEditingController();
  final _discardKey = GlobalKey<DiscardChangesScopeState>();
  String _original = '';
  String? _error;
  bool _loading = true;
  bool _saving = false;

  bool get _dirty => !_loading && _error == null && _controller.text != _original;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _load();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  String get _uri =>
      storeUriWithRef(widget.space, widget.deviceId, widget.relPath);

  Future<void> _load() async {
    try {
      final bytes = await StoreUriReader.instance.read(_uri);
      final text = const Utf8Decoder().convert(bytes);
      if (!mounted) return;
      _original = text;
      _controller.text = text;
      setState(() {
        _loading = false;
        _error = null;
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
    if (_saving) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      final store = await StoreService.instance.localStore();
      await store.putBytes(
        deviceId: widget.deviceId,
        space: widget.space,
        path: widget.relPath,
        bytes: Uint8List.fromList(utf8.encode(_controller.text)),
      );
      if (!mounted) return;
      _original = _controller.text;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.storage_browserSaved)));
      await _discardKey.currentState?.allowPop();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.storage_browserSaveFailed('$e'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DiscardChangesScope(
      key: _discardKey,
      dirty: _dirty,
      child: Scaffold(
      appBar: AppBar(
        title: Text(p.basename(widget.relPath)),
        actions: [
          TextButton.icon(
            onPressed: _loading || _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check, size: 20),
            label: Text(l10n.common_save),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l10n.common_operationFailed(_error!),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () {
                            setState(() {
                              _loading = true;
                              _error = null;
                            });
                            _load();
                          },
                          child: Text(l10n.common_retry),
                        ),
                      ],
                    ),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
      ),
    );
  }
}
