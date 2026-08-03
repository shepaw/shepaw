import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../models/store_attachment_ref.dart';
import '../../l10n/app_localizations.dart';
import '../../storage/device_identity.dart';
import '../../storage/local_store.dart';
import '../../storage/store_protocol.dart';
import '../../storage/store_service.dart';

/// 从本机储物袋 store 浏览并选择文件，供聊天附件等场景使用。
class StorageFilePickerScreen extends StatefulWidget {
  const StorageFilePickerScreen({
    super.key,
    this.maxSelection = 9,
  });

  /// 最多可选文件数（通常为聊天待发送队列剩余容量）。
  final int maxSelection;

  @override
  State<StorageFilePickerScreen> createState() =>
      _StorageFilePickerScreenState();
}

class _StorageFilePickerScreenState extends State<StorageFilePickerScreen> {
  static const _pageStep = 100;

  String _selfId = '';
  String _space = StoreSpace.files;
  String _prefix = '';
  int _limit = _pageStep;
  bool _busy = false;
  bool _loading = true;
  List<StoreEntry> _entries = const [];
  String? _error;
  final Map<String, StoreEntry> _selectedEntries = {};

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final self = await DeviceIdentity.deviceId();
    if (!mounted) return;
    setState(() => _selfId = self);
    await _reload();
  }

  String _entryKey(StoreEntry entry) => '$_space:${entry.path}';

  Future<void> _reload() async {
    if (_selfId.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final store = await StoreService.instance.localStore();
      final entries = await store.list(
        _selfId,
        _space,
        prefix: _prefix.isEmpty ? null : _prefix,
        limit: _limit,
      );
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _entries = const [];
        _loading = false;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<File?> _resolveFile(StoreEntry entry) async {
    final store = await StoreService.instance.localStore();
    final abs = p.joinAll([
      store.root.path,
      _selfId,
      _space,
      ...entry.path.split('/'),
    ]);
    final file = File(abs);
    if (!await file.exists()) return null;
    return file;
  }

  void _toggleSelection(StoreEntry entry) {
    final key = _entryKey(entry);
    setState(() {
      if (_selectedEntries.containsKey(key)) {
        _selectedEntries.remove(key);
      } else if (_selectedEntries.length < widget.maxSelection) {
        _selectedEntries[key] = entry;
      }
    });
  }

  bool _isSelected(StoreEntry entry) =>
      _selectedEntries.containsKey(_entryKey(entry));

  Future<void> _confirmSelection() async {
    if (_selectedEntries.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final refs = <StoreAttachmentRef>[];
      for (final entry in _selectedEntries.values) {
        final file = await _resolveFile(entry);
        if (file == null) continue;
        refs.add(StoreAttachmentRef.fromEntry(
          deviceId: _selfId,
          space: _space,
          entry: entry,
        ));
      }
      if (!mounted) return;
      Navigator.of(context).pop(refs);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _displayName(StoreEntry entry) {
    final parts = entry.path.split('/');
    return parts.isNotEmpty ? parts.last : entry.path;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final atLimit = _selectedEntries.length >= widget.maxSelection;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.chat_storageFilePickerTitle),
        actions: [
          if (_selectedEntries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Text(
                  l10n.chat_storageFilePickerSelected(_selectedEntries.length),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ),
          TextButton(
            onPressed:
                _selectedEntries.isEmpty || _busy ? null : _confirmSelection,
            child: Text(l10n.chat_storageFilePickerConfirm),
          ),
        ],
      ),
      body: _loading && _entries.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  l10n.chat_storageFilePickerHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final space in StoreSpace.browserSpaces)
                      ChoiceChip(
                        label: Text(space),
                        selected: _space == space,
                        onSelected: _busy
                            ? null
                            : (selected) {
                                if (!selected) return;
                                setState(() {
                                  _space = space;
                                  _limit = _pageStep;
                                  _selectedEntries.clear();
                                });
                                _reload();
                              },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  decoration: InputDecoration(
                    labelText: l10n.storage_browserPrefix,
                    hintText: l10n.storage_browserPrefixHint,
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.filter_alt_outlined),
                      onPressed: _busy ? null : _reload,
                    ),
                  ),
                  onChanged: (v) => _prefix = v.trim(),
                  onSubmitted: (_) {
                    setState(() => _limit = _pageStep);
                    _reload();
                  },
                ),
                const SizedBox(height: 8),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      _error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  )
                else if (_entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      l10n.chat_storageFilePickerEmpty,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                else ...[
                  Text(
                    l10n.storage_browserCount(_entries.length),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 4),
                  ..._entries.map((entry) {
                    final selected = _isSelected(entry);
                    final disabled = !selected && atLimit;
                    return CheckboxListTile(
                      value: selected,
                      onChanged: _busy || disabled
                          ? null
                          : (_) => _toggleSelection(entry),
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.insert_drive_file_outlined, size: 20),
                      title: Text(
                        _displayName(entry),
                        style: Theme.of(context).textTheme.bodyMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${entry.path}\n${_fmtBytes(entry.size)}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      isThreeLine: true,
                    );
                  }),
                  if (_entries.length >= _limit)
                    Align(
                      alignment: Alignment.center,
                      child: TextButton(
                        onPressed: _busy
                            ? null
                            : () {
                                setState(() => _limit += _pageStep);
                                _reload();
                              },
                        child: Text(l10n.storage_browserLoadMore),
                      ),
                    ),
                ],
              ],
            ),
    );
  }
}
