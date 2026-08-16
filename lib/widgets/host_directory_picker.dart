import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Split a typed path into directory parent + name prefix (Hub CwdPathInput).
({String parent, String prefix}) splitHostPathQuery(String value) {
  final idx = math.max(value.lastIndexOf('/'), value.lastIndexOf('\\'));
  if (idx < 0) return (parent: '', prefix: value);
  final parent = value.substring(0, idx);
  return (
    parent: parent.isNotEmpty ? parent : value.substring(0, 1),
    prefix: value.substring(idx + 1),
  );
}

bool _looksBrowsablePath(String parent) {
  if (parent.startsWith('/') || parent.startsWith('~')) return true;
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(parent);
}

String _normalizePathKey(String path) {
  var s = path.trim();
  while (s.length > 1 && (s.endsWith('/') || s.endsWith('\\'))) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

typedef HostFsBrowseFn = Future<HostFsBrowseResult> Function(String? path);

/// Directory picker matching Hub `DirectoryPickerModal`: list dirs, up/home,
/// confirm current path. Empty start path browses the user home.
///
/// The address bar is editable: typing filters the listing by name prefix and
/// debounced-browses the parent directory when the path changes.
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
  final _pathController = TextEditingController();
  final _pathFocus = FocusNode();

  HostFsBrowseResult? _result;
  String? _error;
  String? _notice;
  bool _loading = true;
  String _nameFilter = '';
  Timer? _pathDebounce;
  int _loadGen = 0;

  bool get _zh =>
      Localizations.localeOf(context).languageCode.startsWith('zh');

  List<HostFsBrowseEntry> get _visibleEntries {
    final entries = _result?.entries ?? const <HostFsBrowseEntry>[];
    if (_nameFilter.isEmpty) return entries;
    final pref = _nameFilter.toLowerCase();
    return [
      for (final e in entries)
        if (e.name.toLowerCase().startsWith(pref)) e,
    ];
  }

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

  @override
  void dispose() {
    _pathDebounce?.cancel();
    _pathController.dispose();
    _pathFocus.dispose();
    super.dispose();
  }

  void _setPathField(String path, {String nameFilter = ''}) {
    if (_pathController.text != path) {
      _pathController.value = TextEditingValue(
        text: path,
        selection: TextSelection.collapsed(offset: path.length),
      );
    }
    _nameFilter = nameFilter;
  }

  Future<void> _load(
    String? path, {
    bool softFallback = false,
    bool syncPathField = true,
    String? keepFilter,
  }) async {
    final gen = ++_loadGen;
    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
    });
    try {
      final data = await widget.browse(path);
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _result = data;
        _loading = false;
        if (syncPathField) {
          _setPathField(data.path, nameFilter: keepFilter ?? '');
        } else if (keepFilter != null) {
          _nameFilter = keepFilter;
        }
      });
    } catch (e) {
      if (softFallback && path != null && path.trim().isNotEmpty) {
        try {
          final data = await widget.browse(null);
          if (!mounted || gen != _loadGen) return;
          setState(() {
            _result = data;
            _notice = _zh
                ? '路径不存在，已回到用户目录：$path'
                : 'Path missing; fell back to home: $path';
            _loading = false;
            if (syncPathField) _setPathField(data.path);
          });
          return;
        } catch (homeErr) {
          if (!mounted || gen != _loadGen) return;
          setState(() {
            _result = null;
            _error = homeErr.toString();
            _loading = false;
          });
          return;
        }
      }
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _result = null;
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _onPathTextChanged(String value) {
    final split = splitHostPathQuery(value);
    setState(() => _nameFilter = split.prefix);

    _pathDebounce?.cancel();
    _pathDebounce = Timer(const Duration(milliseconds: 180), () {
      unawaited(_applyTypedPath(value));
    });
  }

  Future<void> _applyTypedPath(String value) async {
    final trimmed = value.trimRight();
    if (trimmed.isEmpty) return;

    // Trailing separator → treat as "enter this directory".
    if (trimmed.endsWith('/') || trimmed.endsWith('\\')) {
      final dir = _normalizePathKey(trimmed);
      if (dir.isEmpty || !_looksBrowsablePath(dir)) return;
      if (_result != null &&
          _normalizePathKey(_result!.path) == _normalizePathKey(dir)) {
        setState(() => _nameFilter = '');
        return;
      }
      await _load(dir, syncPathField: false, keepFilter: '');
      return;
    }

    final split = splitHostPathQuery(trimmed);
    if (!_looksBrowsablePath(split.parent)) return;

    final parentKey = _normalizePathKey(split.parent);
    final currentKey =
        _result == null ? null : _normalizePathKey(_result!.path);
    if (currentKey == parentKey) {
      // Already listing this parent; filter only.
      if (mounted) setState(() => _nameFilter = split.prefix);
      return;
    }

    await _load(
      split.parent,
      syncPathField: false,
      keepFilter: split.prefix,
    );
  }

  void _submitPathField() {
    _pathDebounce?.cancel();
    final raw = _pathController.text.trim();
    if (raw.isEmpty) {
      unawaited(_load(null));
      return;
    }
    final target = _normalizePathKey(raw);
    unawaited(_load(target, softFallback: true));
  }

  void _enter(HostFsBrowseEntry entry) => unawaited(_load(entry.path));

  void _goUp() {
    final parent = _result?.parent;
    if (parent != null) unawaited(_load(parent));
  }

  void _goHome() => unawaited(_load(null));

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
                  child: TextField(
                    controller: _pathController,
                    focusNode: _pathFocus,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: _zh ? '输入路径…' : 'Type a path…',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: colorScheme.outlineVariant),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: colorScheme.outlineVariant),
                      ),
                    ),
                    onChanged: _onPathTextChanged,
                    onSubmitted: (_) => _submitPathField(),
                    textInputAction: TextInputAction.go,
                    inputFormatters: [
                      // Allow Enter to submit without inserting a newline.
                      FilteringTextInputFormatter.deny(RegExp(r'[\n\r]')),
                    ],
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
                  ? '可编辑路径并即时过滤；回车进入该目录；确认选择当前路径。'
                  : 'Edit the path to filter; Enter opens it; confirm selects the current folder.',
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
            TextButton(
              onPressed: _goHome,
              child: Text(_zh ? '回到用户目录' : 'Back to home'),
            ),
          ],
        ),
      );
    }
    if (_result == null) return const SizedBox.shrink();
    final visible = _visibleEntries;
    if (visible.isEmpty) {
      return Center(
        child: Text(
          _nameFilter.isEmpty
              ? (_zh ? '没有子目录' : 'No subdirectories')
              : (_zh ? '无匹配「$_nameFilter」' : 'No match for "$_nameFilter"'),
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      itemCount: visible.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: colorScheme.outlineVariant),
      itemBuilder: (context, index) {
        final entry = visible[index];
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
