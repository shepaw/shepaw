import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// One subdirectory from a host filesystem browse.
class HostFsBrowseEntry {
  const HostFsBrowseEntry({required this.name, required this.path});

  final String name;
  final String path;
}

/// Result of listing subdirectories on a host (local or remote Hub).
class HostFsBrowseResult {
  const HostFsBrowseResult({
    required this.path,
    required this.parent,
    required this.entries,
  });

  final String path;
  final String? parent;
  final List<HostFsBrowseEntry> entries;
}

/// Resolve empty / `~` paths to the local user home (mirrors Hub `resolveBrowsePath`).
String resolveLocalBrowsePath(String? raw) {
  final input = (raw ?? '').trim();
  final home = _localHomeDirectory();
  if (input.isEmpty) return home;
  if (input == '~') return home;
  if (input.startsWith('~/') || input.startsWith('~\\')) {
    return p.join(home, input.substring(2));
  }
  return p.normalize(input);
}

String _localHomeDirectory() {
  if (Platform.isWindows) {
    final profile = Platform.environment['USERPROFILE'];
    if (profile != null && profile.isNotEmpty) return profile;
  }
  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) return home;
  return Directory.current.path;
}

String? _localParentOf(String absolutePath) {
  final parent = p.dirname(absolutePath);
  if (parent == absolutePath) return null;
  return parent;
}

/// List local subdirectories (files omitted). Empty [rawPath] → user home.
Future<HostFsBrowseResult> browseLocalDirectory(String? rawPath) async {
  final absolute = resolveLocalBrowsePath(rawPath);
  final dir = Directory(absolute);
  if (!await dir.exists()) {
    throw FileSystemException('Directory does not exist', absolute);
  }
  final entries = <HostFsBrowseEntry>[];
  await for (final entity in dir.list(followLinks: false)) {
    final name = p.basename(entity.path);
    if (name == '.' || name == '..') continue;
    try {
      if (entity is Directory) {
        entries.add(HostFsBrowseEntry(name: name, path: entity.path));
      } else if (entity is Link) {
        final target = Directory(entity.path);
        if (await target.exists()) {
          entries.add(HostFsBrowseEntry(name: name, path: entity.path));
        }
      }
    } catch (_) {
      /* skip unreadable */
    }
  }
  entries.sort(
    (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
  );
  return HostFsBrowseResult(
    path: absolute,
    parent: _localParentOf(absolute),
    entries: entries,
  );
}

typedef HostFsBrowseFn = Future<HostFsBrowseResult> Function(String? path);

/// Directory picker matching Hub `DirectoryPickerModal`: list dirs, up/home,
/// confirm current path. Empty start path browses the user home.
Future<String?> showHostDirectoryPicker({
  required BuildContext context,
  required HostFsBrowseFn browse,
  String? initialPath,
  String? title,
}) {
  final zh = Localizations.localeOf(context).languageCode.startsWith('zh');
  return showDialog<String>(
    context: context,
    builder: (ctx) => _HostDirectoryPickerDialog(
      browse: browse,
      initialPath: initialPath,
      title: title ?? (zh ? '选择目录' : 'Choose directory'),
    ),
  );
}

class _HostDirectoryPickerDialog extends StatefulWidget {
  const _HostDirectoryPickerDialog({
    required this.browse,
    required this.title,
    this.initialPath,
  });

  final HostFsBrowseFn browse;
  final String? initialPath;
  final String title;

  @override
  State<_HostDirectoryPickerDialog> createState() =>
      _HostDirectoryPickerDialogState();
}

class _HostDirectoryPickerDialogState extends State<_HostDirectoryPickerDialog> {
  HostFsBrowseResult? _result;
  String? _error;
  String? _notice;
  bool _loading = true;

  bool get _zh =>
      Localizations.localeOf(context).languageCode.startsWith('zh');

  @override
  void initState() {
    super.initState();
    final start = widget.initialPath?.trim();
    unawaited(
      _load(
        start != null && start.isNotEmpty ? start : null,
        softFallback: true,
      ),
    );
  }

  Future<void> _load(String? path, {bool softFallback = false}) async {
    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
    });
    try {
      final data = await widget.browse(path);
      if (!mounted) return;
      setState(() {
        _result = data;
        _loading = false;
      });
    } catch (e) {
      if (softFallback && path != null && path.trim().isNotEmpty) {
        try {
          final data = await widget.browse(null);
          if (!mounted) return;
          setState(() {
            _result = data;
            _notice = _zh
                ? '路径不存在，已回到用户目录：$path'
                : 'Path missing; fell back to home: $path';
            _loading = false;
          });
          return;
        } catch (homeErr) {
          if (!mounted) return;
          setState(() {
            _result = null;
            _error = homeErr.toString();
            _loading = false;
          });
          return;
        }
      }
      if (!mounted) return;
      setState(() {
        _result = null;
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _enter(HostFsBrowseEntry entry) => unawaited(_load(entry.path));

  void _goUp() {
    final parent = _result?.parent;
    if (parent != null) unawaited(_load(parent));
  }

  void _goHome() => unawaited(_load(null));

  Future<void> _enterPathManually() async {
    final controller = TextEditingController(text: _result?.path ?? '');
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_zh ? '手动输入路径' : 'Enter path'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: _zh ? '绝对路径' : 'Absolute path',
            hintText: _zh ? '/Users/me/project' : '/Users/me/project',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(_zh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(_zh ? '确定' : 'OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted) return;
    if (path == null || path.isEmpty) return;
    // Try to open it in the browser; if that fails, still return the typed path.
    try {
      await _load(path, softFallback: false);
      if (!mounted) return;
      if (_result != null && _error == null) return;
    } catch (_) {
      /* fall through */
    }
    if (!mounted) return;
    Navigator.of(context).pop(path);
  }

  void _confirm() {
    final path = _result?.path;
    if (path != null && path.isNotEmpty) {
      Navigator.of(context).pop(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final canConfirm = !_loading && _error == null && _result != null;

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: _zh ? '上级' : 'Up',
                  onPressed: _loading || _result?.parent == null ? null : _goUp,
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: _zh ? '用户目录' : 'Home',
                  onPressed: _loading ? null : _goHome,
                  icon: const Icon(Icons.home_outlined),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: Text(
                      _result?.path ??
                          (_loading
                              ? (_zh ? '加载中…' : 'Loading…')
                              : '—'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                    ),
                  ),
                ),
              ],
            ),
            if (_notice != null) ...[
              const SizedBox(height: 8),
              Text(
                _notice!,
                style: TextStyle(color: colorScheme.tertiary, fontSize: 12),
              ),
            ],
            const SizedBox(height: 8),
            Container(
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _buildList(colorScheme),
            ),
            const SizedBox(height: 8),
            Text(
              _zh
                  ? '点击子目录进入；确认将选择当前路径。'
                  : 'Tap a folder to enter; confirm selects the current path.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_zh ? '取消' : 'Cancel'),
        ),
        TextButton(
          onPressed: () => unawaited(_enterPathManually()),
          child: Text(_zh ? '手动输入' : 'Type path'),
        ),
        FilledButton(
          onPressed: canConfirm ? _confirm : null,
          child: Text(_zh ? '选择此目录' : 'Select'),
        ),
      ],
    );
  }

  Widget _buildList(ColorScheme colorScheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_error!, style: TextStyle(color: colorScheme.error)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed: _goHome,
                  child: Text(_zh ? '回到用户目录' : 'Back to home'),
                ),
                TextButton(
                  onPressed: () => unawaited(_enterPathManually()),
                  child: Text(_zh ? '手动输入路径' : 'Enter path manually'),
                ),
              ],
            ),
          ],
        ),
      );
    }
    final result = _result;
    if (result == null) return const SizedBox.shrink();
    if (result.entries.isEmpty) {
      return Center(
        child: Text(
          _zh ? '没有子目录' : 'No subdirectories',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      itemCount: result.entries.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: colorScheme.outlineVariant),
      itemBuilder: (context, index) {
        final entry = result.entries[index];
        return ListTile(
          dense: true,
          leading: Icon(Icons.folder_outlined, color: colorScheme.primary),
          title: Text(entry.name),
          onTap: () => _enter(entry),
        );
      },
    );
  }
}
