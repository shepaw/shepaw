import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import '../services/store_open_service.dart';
import '../storage/device_identity.dart';
import '../storage/local_store.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import '../storage/store_uri_reader.dart';
import '../utils/layout_utils.dart';

class _BrowsedFile {
  const _BrowsedFile({required this.space, required this.entry});

  final String space;
  final StoreEntry entry;

  String get path => entry.path;
  int get size => entry.size;
  int get mtimeMs => entry.mtimeMs;
}

/// 浏览 App store 正式文件。
///
/// - 默认浏览本机全部空间，可删/导出；
/// - 传入 [deviceId] 可浏览配对设备的共享分区（[readOnly] 默认 true，不可删）。
/// - 「最近」平铺按修改时间倒序；「空间」按分区/文件夹层级导航。
class StorageBrowserScreen extends StatefulWidget {
  const StorageBrowserScreen({
    super.key,
    this.deviceId,
    this.deviceName,
    this.readOnly = false,
    this.initialSpace,
    this.title,
    this.extraActions,
    this.extraMenuItems,
    this.onExtraMenuSelected,
    this.usedBytes,
  });

  /// 目标设备 fingerprint；null = 本机。
  final String? deviceId;

  /// 展示用设备名（远端浏览时用）。
  final String? deviceName;

  /// 只读模式：隐藏删除；远端默认只读。
  final bool readOnly;

  /// 初始分区（仅影响「空间」Tab 起始位置）；远端默认 files。
  final String? initialSpace;

  /// 覆盖 AppBar 标题；null 时用默认「存储文件」文案。
  final String? title;

  /// 追加到 AppBar actions；桌面端使用。
  final List<Widget>? extraActions;

  /// 移动端「更多」菜单追加项。
  final List<PopupMenuEntry<dynamic>> Function(BuildContext context)?
      extraMenuItems;

  /// [extraMenuItems] 选中回调。
  final void Function(dynamic value)? onExtraMenuSelected;

  /// 非 null 时在 AppBar 展示「已使用 xxx」轻量 badge。
  final int? usedBytes;

  @override
  State<StorageBrowserScreen> createState() => _StorageBrowserScreenState();
}

class _StorageBrowserScreenState extends State<StorageBrowserScreen>
    with SingleTickerProviderStateMixin {
  static const _listLimit = 5000;
  static const _folderMarker = '__folder__';
  static const _menuNewFolder = Object();
  static const _menuUploadLocal = Object();
  static const _menuNewDocument = Object();
  static const _menuNewSpreadsheet = Object();

  /// Align with chat store-open confirm threshold.
  static const _confirmExportBytes = StoreOpenService.confirmMaterializeBytes;

  late final TabController _tabs;

  String _selfId = '';
  String _targetId = '';
  bool _busy = false;
  bool _loading = true;
  List<_BrowsedFile> _files = const [];
  String? _error;

  /// 「空间」Tab：null = 分区根列表；非 null = 已进入某分区。
  String? _navSpace;

  /// 当前分区内路径（无首尾 `/`）；空串 = 分区根。
  String _navPath = '';

  bool get _isRemote =>
      _targetId.isNotEmpty && _selfId.isNotEmpty && _targetId != _selfId;

  bool get _readOnly => widget.readOnly || _isRemote;

  List<String> get _spaces => _isRemote
      ? StoreSpace.sharedReadable
      : StoreSpace.browserSpaces;

  /// 当前已进入的分区；根目录（分区列表）时为 null。
  String? get _effectiveNavSpace => _navSpace;

  /// 写入目标分区；仅在已进入某分区时使用。
  String get _mineSpace => _navSpace ?? StoreSpace.files;

  bool _isMobileLayout(BuildContext context) =>
      !LayoutUtils.isDesktopLayout(context);

  /// 移动端：已进入某分区（含分区根），可返回上级 / store 根。
  bool _mobileInFolder(BuildContext context) =>
      _isMobileLayout(context) && _tabs.index == 1 && _navSpace != null;

  /// 移动端：仅在已进入分区且可写时展示新建/上传。
  bool _mobileMineWritable(BuildContext context) =>
      _isMobileLayout(context) &&
      _tabs.index == 1 &&
      !_readOnly &&
      _navSpace != null;

  bool _isFolderMarkerPath(String path) => p.basename(path) == _folderMarker;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() {
      if (_tabs.indexIsChanging) return;
      if (mounted) setState(() {});
    });
    final initial = widget.initialSpace;
    if (initial != null && initial.isNotEmpty) {
      _navSpace = initial;
    }
    _bootstrap();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  String _uriFor(_BrowsedFile file) =>
      storeUriWithRef(file.space, _targetId, file.path);

  Future<void> _bootstrap() async {
    final self = await DeviceIdentity.deviceId();
    if (!mounted) return;
    final target = widget.deviceId ?? self;
    setState(() {
      _selfId = self;
      _targetId = target;
      if (_isRemote &&
          _navSpace != null &&
          !StoreSpace.sharedReadable.contains(_navSpace)) {
        _navSpace = StoreSpace.files;
        _navPath = '';
      }
    });
    await _reload();
  }

  Future<void> _reload() async {
    if (_targetId.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final all = <_BrowsedFile>[];
      for (final space in _spaces) {
        final entries = await StoreService.instance.listDevice(
          deviceId: _targetId,
          space: space,
          limit: _listLimit,
        );
        for (final e in entries) {
          all.add(_BrowsedFile(space: space, entry: e));
        }
      }
      all.sort((a, b) => b.mtimeMs.compareTo(a.mtimeMs));
      if (!mounted) return;
      setState(() {
        _files = all;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _files = const [];
        _loading = false;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _previewFile(_BrowsedFile file) async {
    if (_targetId.isEmpty) return;
    await StoreOpenService.instance.openStoreUri(context, _uriFor(file));
  }

  Future<void> _exportFile(_BrowsedFile file) async {
    final l10n = AppLocalizations.of(context);
    final name = p.basename(file.path);
    if (file.size >= _confirmExportBytes) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.storage_browserExport),
          content: Text(l10n.storage_browserExportConfirmLarge(
            name,
            StoreOpenService.formatBytes(file.size),
          )),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.common_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.common_confirm),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: l10n.storage_browserExport,
    );
    if (dir == null || !mounted) return;

    setState(() => _busy = true);
    try {
      var destPath = p.join(dir, name);
      var dest = File(destPath);
      if (await dest.exists()) {
        final stem = p.withoutExtension(name);
        final ext = p.extension(name);
        var i = 1;
        do {
          destPath = p.join(dir, '$stem ($i)$ext');
          dest = File(destPath);
          i++;
        } while (await dest.exists());
      }
      await StoreUriReader.instance.copyTo(_uriFor(file), dest);
      if (!mounted) return;
      _toast(l10n.storage_browserExportDone(dest.path));
    } catch (e) {
      if (mounted) _toast(l10n.storage_browserExportFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteFile(_BrowsedFile file) async {
    if (_readOnly) {
      _toast(AppLocalizations.of(context).storage_browserDeleteDenied);
      return;
    }
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.storage_browserDeleteTitle),
        content: Text(l10n.storage_browserDeleteConfirm(file.path)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.common_confirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final store = await StoreService.instance.localStore();
      await store.delete(_targetId, file.space, file.path);
      _toast(l10n.storage_browserDeleted(file.path));
      await _reload();
    } on StoreException catch (e) {
      _toast(l10n.storage_browserDeleteFailed(
          e.message.isEmpty ? e.code : e.message));
    } catch (e) {
      _toast(l10n.storage_browserDeleteFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showEntryActions(_BrowsedFile file) async {
    final l10n = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('${file.space}/${file.path}',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(_fmtBytes(file.size)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.visibility_outlined),
              title: Text(l10n.storage_browserPreview),
              onTap: () {
                Navigator.of(ctx).pop();
                _previewFile(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: Text(l10n.storage_browserExport),
              onTap: () {
                Navigator.of(ctx).pop();
                _exportFile(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: Text(l10n.storage_browserVersions),
              onTap: () {
                Navigator.of(ctx).pop();
                _showVersions(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.account_tree_outlined),
              title: Text(l10n.storage_browserManifest),
              onTap: () {
                Navigator.of(ctx).pop();
                _showManifest(file);
              },
            ),
            if (!_readOnly)
              ListTile(
                leading: Icon(Icons.delete_outline,
                    color: Theme.of(ctx).colorScheme.error),
                title: Text(l10n.storage_browserDelete),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _deleteFile(file);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showVersions(_BrowsedFile file) async {
    final l10n = AppLocalizations.of(context);
    if (await StoreService.instance.isMaster()) {
      _toast(l10n.storage_browserNeedMaster);
      return;
    }
    setState(() => _busy = true);
    Map<String, dynamic>? data;
    String? err;
    try {
      data = await StoreService.instance.versionsList(
        space: file.space,
        device: _targetId,
        path: file.path,
      );
      if (data != null && data['_error'] != null) {
        err = '${data['_error']}: ${data['message'] ?? ''}';
        data = null;
      }
    } catch (e) {
      err = '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (err != null) {
      _toast(l10n.storage_browserVersionsFailed(err));
      return;
    }
    final versions = (data?['versions'] as List?) ?? const [];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (_, scroll) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l10n.storage_browserVersionsTitle,
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            Expanded(
              child: versions.isEmpty
                  ? Center(child: Text(l10n.storage_browserVersionsEmpty))
                  : ListView.builder(
                      controller: scroll,
                      itemCount: versions.length,
                      itemBuilder: (_, i) {
                        final v = versions[i] as Map;
                        final ver = v['v'] ?? '?';
                        final size = v['size'] ?? 0;
                        final sha = '${v['sha256'] ?? ''}';
                        final shaShort =
                            sha.length >= 16 ? sha.substring(0, 16) : sha;
                        final protected = v['protected'] == true;
                        return ListTile(
                          dense: true,
                          leading: Text('v$ver'),
                          title: Text(_fmtBytes(size is int ? size : 0)),
                          subtitle: Text(shaShort),
                          trailing: protected
                              ? const Icon(Icons.lock_outline, size: 16)
                              : null,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showManifest(_BrowsedFile file) async {
    final l10n = AppLocalizations.of(context);
    if (await StoreService.instance.isMaster()) {
      _toast(l10n.storage_browserNeedMaster);
      return;
    }
    setState(() => _busy = true);
    Map<String, dynamic>? data;
    String? err;
    try {
      data = await StoreService.instance.manifest(
        space: file.space,
        device: _targetId,
        path: file.path,
      );
      if (data != null && data['_error'] != null) {
        err = '${data['_error']}: ${data['message'] ?? ''}';
        data = null;
      }
    } catch (e) {
      err = '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (err != null) {
      _toast(l10n.storage_browserManifestFailed(err));
      return;
    }
    if (data == null || data.isEmpty) {
      _toast(l10n.storage_browserManifestEmpty);
      return;
    }
    final producer = data['producer']?.toString() ?? '';
    final summary = data['summary']?.toString() ?? '';
    final parents = (data['parent_uris'] as List?)?.join('\n') ?? '';
    final state = data['state']?.toString() ?? '';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.storage_browserManifestTitle),
        content: SingleChildScrollView(
          child: SelectableText([
            if (state.isNotEmpty) 'state: $state',
            if (producer.isNotEmpty) 'producer: $producer',
            if (summary.isNotEmpty) 'summary: $summary',
            if (parents.isNotEmpty) 'parents:\n$parents',
            if (state.isEmpty &&
                producer.isEmpty &&
                summary.isEmpty &&
                parents.isEmpty)
              l10n.storage_browserManifestEmpty,
          ].join('\n\n')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.common_confirm),
          ),
        ],
      ),
    );
  }

  Future<void> _openSearch() async {
    final l10n = AppLocalizations.of(context);
    if (_mobileInFolder(context)) {
      await showSearch<void>(
        context: context,
        delegate: _FolderScopedSearchDelegate(
          files: _files,
          space: _mineSpace,
          pathPrefix: _navPath.isEmpty ? '' : '$_navPath/',
          onOpen: _previewFile,
        ),
      );
      return;
    }
    if (await StoreService.instance.isMaster()) {
      if (!mounted) return;
      _toast(l10n.storage_browserNeedMaster);
      return;
    }
    if (!mounted) return;
    await showSearch<void>(
      context: context,
      delegate: _StoreSearchDelegate(
        space: _navSpace ?? StoreSpace.files,
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _fmtRelativeTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    final time =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final locale = Localizations.localeOf(context);
    final datePart = locale.languageCode == 'zh'
        ? '${t.month}月${t.day}日'
        : '${t.month}/${t.day}';
    return '$datePart $time';
  }

  String _destRelPath(String name) {
    final normalized = normalizeStorePath(name);
    if (_navPath.isEmpty) return normalized;
    return normalizeStorePath('$_navPath/$normalized');
  }

  Future<void> _commitBytes({
    required String space,
    required String path,
    required Uint8List bytes,
  }) async {
    final sha = crypto.sha256.convert(bytes).toString();
    final store = await StoreService.instance.localStore();
    final (uid, _) = await store.writeBegin(
      deviceId: _targetId,
      space: space,
      path: path,
      size: bytes.length,
      sha256: sha,
    );
    if (bytes.isNotEmpty) {
      await store.writeChunk(_targetId, space, uid, 0, bytes);
    }
    final (_, failed) = await store.commit(_targetId, space, [uid]);
    if (failed.isNotEmpty) {
      throw StateError(failed.join(', '));
    }
  }

  Future<void> _promptNewFolder() async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.storage_browserNewFolder),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration:
              InputDecoration(hintText: l10n.storage_browserNewFolderHint),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(l10n.common_confirm),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || _busy) return;
    if (name.contains('/') || name.contains('\\')) {
      _toast(l10n.storage_browserNewFolderFailed('invalid name'));
      return;
    }
    setState(() => _busy = true);
    try {
      final markerPath = _destRelPath('$name/$_folderMarker');
      await _commitBytes(
        space: _mineSpace,
        path: markerPath,
        bytes: Uint8List(0),
      );
      await _reload();
    } catch (e) {
      _toast(l10n.storage_browserNewFolderFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uploadLocalFiles() async {
    final l10n = AppLocalizations.of(context);
    final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (picked == null || picked.files.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      for (final item in picked.files) {
        final localPath = item.path;
        if (localPath == null) continue;
        final file = File(localPath);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        final dest = _destRelPath(p.basename(localPath));
        await _commitBytes(space: _mineSpace, path: dest, bytes: bytes);
        if (mounted) {
          _toast(l10n.storage_browserUploadDone(p.basename(localPath)));
        }
      }
      await _reload();
    } catch (e) {
      _toast(l10n.storage_browserUploadFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _uniqueBaseName(String base, String ext) {
    final existing = _files
        .where((f) => f.space == _mineSpace)
        .map((f) => f.path)
        .toSet();
    var i = 0;
    while (true) {
      final suffix = i == 0 ? '' : ' ($i)';
      final fileName = ext.isEmpty ? '$base$suffix' : '$base$suffix.$ext';
      final rel = _destRelPath(fileName);
      if (!existing.contains(rel)) return fileName;
      i++;
    }
  }

  Future<void> _createNewDocument({required bool spreadsheet}) async {
    final l10n = AppLocalizations.of(context);
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final fileName = spreadsheet
          ? _uniqueBaseName(l10n.storage_browserNewSpreadsheet, 'csv')
          : _uniqueBaseName(l10n.storage_browserNewDocument, 'md');
      final title = p.basenameWithoutExtension(fileName);
      final bytes = spreadsheet
          ? utf8.encode('$title\n')
          : utf8.encode('# $title\n\n');
      await _commitBytes(
        space: _mineSpace,
        path: _destRelPath(fileName),
        bytes: Uint8List.fromList(bytes),
      );
      await _reload();
    } catch (e) {
      _toast(l10n.storage_browserNewFileFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _handleMobileMoreSelected(dynamic value) {
    if (value == _menuNewFolder) {
      _promptNewFolder();
      return;
    }
    if (value == _menuUploadLocal) {
      _uploadLocalFiles();
      return;
    }
    if (value == _menuNewDocument) {
      _createNewDocument(spreadsheet: false);
      return;
    }
    if (value == _menuNewSpreadsheet) {
      _createNewDocument(spreadsheet: true);
      return;
    }
    widget.onExtraMenuSelected?.call(value);
  }

  String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _fmtMtime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  String _fmtRecentAccess(int ms, AppLocalizations l10n) {
    final rel = _fmtRelativeTime(ms);
    if (rel.isEmpty) return '';
    return l10n.storage_browserLastAccessed(rel);
  }

  String _fmtLastModified(int ms, AppLocalizations l10n) {
    final rel = _fmtRelativeTime(ms);
    if (rel.isEmpty) return '';
    return l10n.storage_browserLastModified(rel);
  }

  String _fileName(String path) {
    final parts = path.split('/');
    return parts.isNotEmpty ? parts.last : path;
  }

  void _enterSpace(String space) {
    setState(() {
      _navSpace = space;
      _navPath = '';
    });
  }

  void _enterFolder(String name) {
    setState(() {
      _navPath = _navPath.isEmpty ? name : '$_navPath/$name';
    });
  }

  void _navUp() {
    setState(() {
      if (_navPath.isNotEmpty) {
        final i = _navPath.lastIndexOf('/');
        _navPath = i < 0 ? '' : _navPath.substring(0, i);
      } else {
        _navSpace = null;
      }
    });
  }

  void _navToRoot() {
    setState(() {
      _navSpace = null;
      _navPath = '';
    });
  }

  void _navToSpaceRoot() {
    setState(() => _navPath = '');
  }

  void _navToPath(String path) {
    setState(() => _navPath = path);
  }

  /// 当前目录下的子文件夹名（排序）与文件。
  ({List<String> folders, List<_BrowsedFile> files}) _folderChildren() {
    final space = _effectiveNavSpace;
    if (space == null) {
      return (folders: const [], files: const []);
    }
    final prefix = _navPath.isEmpty ? '' : '$_navPath/';
    final folders = <String>{};
    final files = <_BrowsedFile>[];
    for (final f in _files) {
      if (f.space != space) continue;
      if (prefix.isEmpty) {
        final slash = f.path.indexOf('/');
        if (slash < 0) {
          if (!_isFolderMarkerPath(f.path)) files.add(f);
        } else {
          folders.add(f.path.substring(0, slash));
        }
      } else {
        if (!f.path.startsWith(prefix)) continue;
        final rest = f.path.substring(prefix.length);
        if (rest.isEmpty) continue;
        final slash = rest.indexOf('/');
        if (slash < 0) {
          if (!_isFolderMarkerPath(f.path)) files.add(f);
        } else {
          folders.add(rest.substring(0, slash));
        }
      }
    }
    final folderList = folders.toList()
      ..sort((a, b) => _folderMtimeMs(space, b).compareTo(_folderMtimeMs(space, a)));
    files.sort((a, b) => b.mtimeMs.compareTo(a.mtimeMs));
    return (folders: folderList, files: files);
  }

  int _folderMtimeMs(String space, String folderName) {
    final prefix = _navPath.isEmpty ? '$folderName/' : '$_navPath/$folderName/';
    var maxMs = 0;
    for (final f in _files) {
      if (f.space != space) continue;
      if (f.path.startsWith(prefix) && f.mtimeMs > maxMs) {
        maxMs = f.mtimeMs;
      }
    }
    return maxMs;
  }

  String _currentFolderTitle() {
    if (_navPath.isNotEmpty) {
      final parts = _navPath.split('/');
      return parts.isNotEmpty ? parts.last : _navPath;
    }
    return _navSpace ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final mobile = _isMobileLayout(context);

    return PopScope(
      canPop: !_mobileInFolder(context),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _mobileInFolder(context)) _navUp();
      },
      child: Scaffold(
        appBar: mobile
            ? (_mobileInFolder(context)
                ? _buildMobileFolderAppBar(l10n)
                : _buildMobileAppBar(l10n))
            : _buildDesktopAppBar(l10n),
        body: _loading && _files.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                controller: _tabs,
                children: [
                  _buildFlatTab(l10n, mobile: mobile),
                  _buildSpaceTab(l10n, mobile: mobile),
                ],
              ),
      ),
    );
  }

  PreferredSizeWidget _buildMobileFolderAppBar(AppLocalizations l10n) {
    return AppBar(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: _navUp,
      ),
      title: Text(
        _currentFolderTitle(),
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
      ),
      actions: _buildMobileActions(l10n, includeCreate: !_readOnly),
    );
  }

  PreferredSizeWidget _buildMobileAppBar(AppLocalizations l10n) {
    return AppBar(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      title: _buildTabHeader(l10n),
      actions: _buildMobileActions(l10n, includeCreate: _mobileMineWritable(context)),
    );
  }

  PreferredSizeWidget _buildDesktopAppBar(AppLocalizations l10n) {
    final used = widget.usedBytes;
    return AppBar(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      title: _buildTabHeader(l10n),
      actions: [
        if (used != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Center(
              child: Text(
                l10n.storage_usedBadge(_fmtBytes(used)),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          ),
        if (!_isRemote)
          IconButton(
            onPressed: _busy ? null : _openSearch,
            icon: const Icon(Icons.search),
            tooltip: l10n.storage_browserSearchTitle,
          ),
        ...?widget.extraActions,
      ],
    );
  }

  Widget _buildTabHeader(AppLocalizations l10n) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _tabChip(
          label: l10n.storage_browserTabRecent,
          selected: _tabs.index == 0,
          onTap: () => _tabs.animateTo(0),
        ),
        const SizedBox(width: 28),
        _tabChip(
          label: l10n.storage_browserTabSpace,
          selected: _tabs.index == 1,
          onTap: () => _tabs.animateTo(1),
        ),
      ],
    );
  }

  Widget _tabChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 3,
              width: selected ? 28 : 0,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildMobileActions(
    AppLocalizations l10n, {
    required bool includeCreate,
  }) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return [
      if (!_isRemote)
        IconButton(
          onPressed: _busy ? null : _openSearch,
          icon: const Icon(Icons.search),
          tooltip: l10n.storage_browserSearchTitle,
        ),
      PopupMenuButton<dynamic>(
        icon: const Icon(Icons.add_circle_outline),
        tooltip: l10n.storage_moreSettings,
        onSelected: _handleMobileMoreSelected,
        itemBuilder: (ctx) => [
          if (includeCreate) ...[
            PopupMenuItem(
              value: _menuNewFolder,
              child: Row(
                children: [
                  Icon(Icons.create_new_folder_outlined, size: 20, color: muted),
                  const SizedBox(width: 12),
                  Expanded(child: Text(l10n.storage_browserNewFolder)),
                ],
              ),
            ),
            PopupMenuItem(
              value: _menuUploadLocal,
              child: Row(
                children: [
                  Icon(Icons.file_upload_outlined, size: 20, color: muted),
                  const SizedBox(width: 12),
                  Expanded(child: Text(l10n.storage_browserUploadLocal)),
                ],
              ),
            ),
            PopupMenuItem(
              value: _menuNewDocument,
              child: Row(
                children: [
                  Icon(Icons.note_add_outlined, size: 20, color: muted),
                  const SizedBox(width: 12),
                  Expanded(child: Text(l10n.storage_browserNewDocument)),
                ],
              ),
            ),
            PopupMenuItem(
              value: _menuNewSpreadsheet,
              child: Row(
                children: [
                  Icon(Icons.grid_on_outlined, size: 20, color: muted),
                  const SizedBox(width: 12),
                  Expanded(child: Text(l10n.storage_browserNewSpreadsheet)),
                ],
              ),
            ),
          ],
          ...?widget.extraMenuItems?.call(ctx),
        ],
      ),
    ];
  }

  Widget _buildFolderIcon() {
    return const Icon(
      Icons.folder_rounded,
      color: Color(0xFFF5C542),
      size: 44,
    );
  }

  Widget _buildMobileFolderRow(String name, AppLocalizations l10n) {
    final space = _mineSpace;
    final modified = _fmtLastModified(_folderMtimeMs(space, name), l10n);
    return InkWell(
      onTap: _busy ? null : () => _enterFolder(name),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 42, child: Center(child: _buildFolderIcon())),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                  ),
                  if (modified.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      modified,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileFolderEmpty(AppLocalizations l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.save_outlined,
              size: 72,
              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.storage_browserFolderEmpty,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocIcon() {
    const iconColor = Color(0xFF5B9BD5);
    const bgColor = Color(0xFFE8F2FC);
    return Container(
      width: 42,
      height: 50,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 22,
            height: 2.5,
            decoration: BoxDecoration(
              color: iconColor,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          const SizedBox(height: 5),
          Container(
            width: 16,
            height: 2.5,
            decoration: BoxDecoration(
              color: iconColor,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileFileRow(
    _BrowsedFile file,
    AppLocalizations l10n, {
    bool useModified = false,
  }) {
    final subtitle = useModified
        ? _fmtLastModified(file.mtimeMs, l10n)
        : _fmtRecentAccess(file.mtimeMs, l10n);
    return InkWell(
      onTap: _busy ? null : () => _previewFile(file),
      onLongPress: _busy ? null : () => _showEntryActions(file),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDocIcon(),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _fileName(file.path),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFlatTab(AppLocalizations l10n, {required bool mobile}) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      );
    }
    if (_files.isEmpty) {
      return Center(
        child: Text(l10n.storage_browserEmpty,
            style: Theme.of(context).textTheme.bodySmall),
      );
    }
    if (mobile) {
      return ListView.separated(
        padding: const EdgeInsets.only(top: 4, bottom: 16),
        itemCount: _files.length,
        separatorBuilder: (_, __) => const SizedBox(height: 2),
        itemBuilder: (context, i) =>
            _buildMobileFileRow(_files[i], l10n),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _files.length,
      itemBuilder: (context, i) {
        final f = _files[i];
        final mtime = _fmtMtime(f.mtimeMs);
        return ListTile(
          dense: true,
          leading: const Icon(Icons.insert_drive_file_outlined, size: 20),
          title: Text(_fileName(f.path), overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              '${f.space}/${f.path}',
              _fmtBytes(f.size),
              if (mtime.isNotEmpty) mtime,
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
          onTap: _busy ? null : () => _previewFile(f),
          trailing: IconButton(
            icon: const Icon(Icons.more_horiz, size: 18),
            onPressed: _busy ? null : () => _showEntryActions(f),
          ),
        );
      },
    );
  }

  Widget _buildSpaceTab(AppLocalizations l10n, {required bool mobile}) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      );
    }

    // store 根：列出各分区，不默认进入 files。
    if (_navSpace == null) {
      return _buildSpaceRootList(l10n, mobile: mobile);
    }

    final children = _folderChildren();
    final empty = children.folders.isEmpty && children.files.isEmpty;

    if (mobile) {
      if (empty) return _buildMobileFolderEmpty(l10n);
      final rows = <Widget>[
        for (final name in children.folders)
          _buildMobileFolderRow(name, l10n),
        for (final f in children.files)
          _buildMobileFileRow(f, l10n, useModified: true),
      ];
      return ListView.separated(
        padding: const EdgeInsets.only(top: 4, bottom: 16),
        itemCount: rows.length,
        separatorBuilder: (_, __) => const SizedBox(height: 2),
        itemBuilder: (_, i) => rows[i],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildBreadcrumb(),
        const Divider(height: 1),
        Expanded(
          child: empty
              ? Center(
                  child: Text(l10n.storage_browserEmpty,
                      style: Theme.of(context).textTheme.bodySmall),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    for (final name in children.folders)
                      ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(name),
                        trailing: const Icon(Icons.chevron_right, size: 20),
                        onTap: () => _enterFolder(name),
                      ),
                    for (final f in children.files)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.insert_drive_file_outlined,
                            size: 20),
                        title: Text(_fileName(f.path),
                            overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            _fmtBytes(f.size),
                            if (_fmtMtime(f.mtimeMs).isNotEmpty)
                              _fmtMtime(f.mtimeMs),
                          ].join(' · '),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        onTap: _busy ? null : () => _previewFile(f),
                        trailing: IconButton(
                          icon: const Icon(Icons.more_horiz, size: 18),
                          onPressed:
                              _busy ? null : () => _showEntryActions(f),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildSpaceRootList(AppLocalizations l10n, {required bool mobile}) {
    if (mobile) {
      return ListView.separated(
        padding: const EdgeInsets.only(top: 4, bottom: 16),
        itemCount: _spaces.length,
        separatorBuilder: (_, __) => const SizedBox(height: 2),
        itemBuilder: (context, i) {
          final space = _spaces[i];
          final count = _files.where((f) => f.space == space).length;
          final subtitle = l10n.storage_browserCount(count);
          return InkWell(
            onTap: _busy ? null : () => _enterSpace(space),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 42, child: Center(child: _buildFolderIcon())),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          space,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    height: 1.35,
                                  ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          subtitle,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final space in _spaces)
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(space),
            subtitle: Text(
              l10n.storage_browserCount(
                  _files.where((f) => f.space == space).length),
              style: Theme.of(context).textTheme.labelSmall,
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _enterSpace(space),
          ),
      ],
    );
  }

  Widget _buildBreadcrumb() {
    final segments = <({String label, VoidCallback? onTap})>[
      (
        label: '/',
        onTap: _navSpace == null && _navPath.isEmpty ? null : _navToRoot,
      ),
    ];
    if (_navSpace != null) {
      segments.add((
        label: _navSpace!,
        onTap: _navPath.isEmpty ? null : _navToSpaceRoot,
      ));
      if (_navPath.isNotEmpty) {
        final parts = _navPath.split('/');
        var acc = '';
        for (var i = 0; i < parts.length; i++) {
          acc = acc.isEmpty ? parts[i] : '$acc/${parts[i]}';
          final target = acc;
          final isLast = i == parts.length - 1;
          segments.add((
            label: parts[i],
            onTap: isLast ? null : () => _navToPath(target),
          ));
        }
      }
    }

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_upward, size: 18),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: _navSpace == null ? null : _navUp,
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < segments.length; i++) ...[
                      if (i > 0)
                        Text(' / ',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                )),
                      InkWell(
                        onTap: segments[i].onTap,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 6),
                          child: Text(
                            segments[i].label,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  fontWeight: segments[i].onTap == null
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  color: segments[i].onTap == null
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StoreSearchDelegate extends SearchDelegate<void> {
  _StoreSearchDelegate({required this.space});

  final String space;
  bool semantic = false;

  @override
  List<Widget>? buildActions(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return [
      IconButton(
        icon: Icon(semantic ? Icons.psychology : Icons.text_fields),
        tooltip: semantic
            ? l10n.storage_browserSearchSemantic
            : l10n.storage_browserSearchKeyword,
        onPressed: () {
          semantic = !semantic;
          if (query.trim().isNotEmpty) {
            showResults(context);
          } else {
            showSuggestions(context);
          }
        },
      ),
      if (query.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.clear),
          onPressed: () => query = '',
        ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final q = query.trim();
    if (q.isEmpty) {
      return Center(child: Text(l10n.storage_browserSearchHint));
    }
    return FutureBuilder<Map<String, dynamic>?>(
      future: StoreService.instance
          .search(q: q, space: space, semantic: semantic),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snap.data;
        if (data != null && data['_error'] != null) {
          return Center(
            child: Text(l10n.storage_browserSearchFailed(
                '${data['_error']}: ${data['message'] ?? ''}')),
          );
        }
        if (snap.hasError) {
          return Center(
              child: Text(l10n.storage_browserSearchFailed('${snap.error}')));
        }
        final list = (data?['results'] as List?) ?? const [];
        final degraded = data?['degraded'] == true;
        final scoreType = '${data?['score_type'] ?? ''}';
        if (list.isEmpty) {
          return Center(child: Text(l10n.storage_browserSearchEmpty));
        }
        return ListView.builder(
          itemCount: list.length + (degraded || scoreType.isNotEmpty ? 1 : 0),
          itemBuilder: (_, i) {
            if (i == 0 && (degraded || scoreType.isNotEmpty)) {
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  degraded
                      ? l10n.storage_browserSearchDegraded
                      : (semantic
                          ? l10n.storage_browserSearchSemantic
                          : l10n.storage_browserSearchKeyword),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              );
            }
            final idx = i - ((degraded || scoreType.isNotEmpty) ? 1 : 0);
            final r = Map<String, dynamic>.from(list[idx] as Map);
            final path = '${r['path'] ?? ''}';
            final snippet = '${r['snippet'] ?? ''}';
            final uri = '${r['uri'] ?? ''}';
            return ListTile(
              title: Text(path, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                snippet.isNotEmpty ? snippet : uri,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              dense: true,
            );
          },
        );
      },
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Text(
        '${l10n.storage_browserSearchHint}'
        ' · ${semantic ? l10n.storage_browserSearchSemantic : l10n.storage_browserSearchKeyword}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _FolderScopedSearchDelegate extends SearchDelegate<void> {
  _FolderScopedSearchDelegate({
    required this.files,
    required this.space,
    required this.pathPrefix,
    required this.onOpen,
  });

  final List<_BrowsedFile> files;
  final String space;
  final String pathPrefix;
  final void Function(_BrowsedFile file) onOpen;

  List<_BrowsedFile> _matches(String q) {
    final needle = q.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    return files.where((f) {
      if (f.space != space) return false;
      if (pathPrefix.isNotEmpty && !f.path.startsWith(pathPrefix)) return false;
      if (p.basename(f.path) == _StorageBrowserScreenState._folderMarker) {
        return false;
      }
      return f.path.toLowerCase().contains(needle) ||
          p.basename(f.path).toLowerCase().contains(needle);
    }).toList()
      ..sort((a, b) => b.mtimeMs.compareTo(a.mtimeMs));
  }

  @override
  List<Widget>? buildActions(BuildContext context) {
    if (query.isEmpty) return null;
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () => query = '',
      ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildResults(BuildContext context) => _buildList(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildList(context);

  Widget _buildList(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final q = query.trim();
    if (q.isEmpty) {
      return Center(child: Text(l10n.storage_browserSearchHint));
    }
    final list = _matches(q);
    if (list.isEmpty) {
      return Center(child: Text(l10n.storage_browserSearchEmpty));
    }
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (_, i) {
        final f = list[i];
        final name = p.basename(f.path);
        return ListTile(
          title: Text(name, overflow: TextOverflow.ellipsis),
          subtitle: Text(f.path, maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () {
            close(context, null);
            onOpen(f);
          },
        );
      },
    );
  }
}
