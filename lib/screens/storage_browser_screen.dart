import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import '../models/store_attachment_ref.dart';
import '../peer/models/peer_store_share.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/store_open_service.dart';
import '../storage/device_identity.dart';
import '../storage/local_store.dart';
import '../storage/store_file_visual.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import '../storage/store_uri_reader.dart';
import '../utils/layout_utils.dart';
import '../widgets/storage/store_file_list_avatar.dart';

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
    this.peerId,
    this.readOnly = false,
    this.initialSpace,
    this.title,
    this.extraActions,
    this.extraMenuItems,
    this.onExtraMenuSelected,
    this.usedBytes,
    this.pickForAttachment = false,
    this.maxPickCount = 9,
  });

  /// 目标设备 fingerprint；null = 本机。
  final String? deviceId;

  /// 展示用设备名（远端浏览时用）。
  final String? deviceName;

  /// 配对关系 id；远端浏览时用于读取入站分享目录。
  final String? peerId;

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

  /// 聊天附件选择：复用浏览排版，多选后 pop [StoreAttachmentRef] 列表。
  final bool pickForAttachment;

  /// [pickForAttachment] 时最多可选文件数。
  final int maxPickCount;

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
  static const _entryPreview = Object();
  static const _entryExport = Object();
  static const _entryVersions = Object();
  static const _entryManifest = Object();
  static const _entryDelete = Object();

  /// Align with chat store-open confirm threshold.
  static const _confirmExportBytes = StoreOpenService.confirmMaterializeBytes;

  late final TabController _tabs;

  String _selfId = '';
  String _targetId = '';
  bool _busy = false;
  bool _loading = true;
  List<_BrowsedFile> _files = const [];
  String? _error;
  final Map<String, _BrowsedFile> _selectedFiles = {};

  /// 「空间」Tab：null = 分区根列表；非 null = 已进入某分区。
  String? _navSpace;

  /// 当前分区内路径（无首尾 `/`）；空串 = 分区根。
  String _navPath = '';

  bool get _isRemote =>
      _targetId.isNotEmpty && _selfId.isNotEmpty && _targetId != _selfId;

  bool get _readOnly => widget.readOnly || _isRemote;

  PeerStoreShareAllowlist? _inboundShares;

  List<String> get _spaces {
    if (!_isRemote) return StoreSpace.browserSpaces;
    final inbound = _inboundShares;
    if (inbound != null && !inbound.isEmpty) {
      final spaces = inbound.spaces.toList()..sort();
      return spaces;
    }
    // 尚未收到 announce 时回退到内置共享分区（ACL 仍会拦截未分享路径）
    return StoreSpace.sharedReadable;
  }

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

  bool get _pickMode => widget.pickForAttachment;

  bool get _atPickLimit => _selectedFiles.length >= widget.maxPickCount;

  String _fileKey(_BrowsedFile file) => '${file.space}:${file.path}';

  bool _isPicked(_BrowsedFile file) => _selectedFiles.containsKey(_fileKey(file));

  void _togglePick(_BrowsedFile file) {
    final key = _fileKey(file);
    setState(() {
      if (_selectedFiles.containsKey(key)) {
        _selectedFiles.remove(key);
      } else if (!_atPickLimit) {
        _selectedFiles[key] = file;
      }
    });
  }

  Future<void> _confirmPick() async {
    if (_selectedFiles.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final refs = <StoreAttachmentRef>[];
      for (final file in _selectedFiles.values) {
        final ref = StoreAttachmentRef.fromEntry(
          deviceId: _targetId,
          space: file.space,
          entry: file.entry,
        );
        if (await ref.resolveLocalFile() == null) continue;
        refs.add(ref);
      }
      if (!mounted) return;
      Navigator.of(context).pop(refs);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onFileTap(_BrowsedFile file) {
    if (_pickMode) {
      _togglePick(file);
      return;
    }
    _previewFile(file);
  }

  List<Widget> _pickModeActions(AppLocalizations l10n) {
    return [
      if (_selectedFiles.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Center(
            child: Text(
              l10n.chat_storageFilePickerSelected(_selectedFiles.length),
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ),
      TextButton(
        onPressed: _selectedFiles.isEmpty || _busy ? null : _confirmPick,
        child: Text(l10n.chat_storageFilePickerConfirm),
      ),
    ];
  }

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
    PeerStoreShareAllowlist? inbound;
    final peerId = widget.peerId;
    if (peerId != null && peerId.isNotEmpty && target != self) {
      try {
        inbound = await PeerStorageService().getInboundStoreAllowlist(peerId);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _selfId = self;
      _targetId = target;
      _inboundShares = inbound;
      if (_isRemote &&
          _navSpace != null &&
          !_spaces.contains(_navSpace)) {
        _navSpace = _spaces.isNotEmpty ? _spaces.first : StoreSpace.files;
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

  void _handleEntryAction(_BrowsedFile file, Object? action) {
    if (action == _entryPreview) {
      _previewFile(file);
    } else if (action == _entryExport) {
      _exportFile(file);
    } else if (action == _entryVersions) {
      _showVersions(file);
    } else if (action == _entryManifest) {
      _showManifest(file);
    } else if (action == _entryDelete) {
      _deleteFile(file);
    }
  }

  List<PopupMenuEntry<Object>> _entryActionItems(AppLocalizations l10n) {
    final errorColor = Theme.of(context).colorScheme.error;
    return [
      PopupMenuItem(
        value: _entryPreview,
        child: Text(l10n.storage_browserPreview),
      ),
      PopupMenuItem(
        value: _entryExport,
        child: Text(l10n.storage_browserExport),
      ),
      PopupMenuItem(
        value: _entryVersions,
        child: Text(l10n.storage_browserVersions),
      ),
      PopupMenuItem(
        value: _entryManifest,
        child: Text(l10n.storage_browserManifest),
      ),
      if (!_readOnly)
        PopupMenuItem(
          value: _entryDelete,
          child: Text(
            l10n.storage_browserDelete,
            style: TextStyle(color: errorColor),
          ),
        ),
    ];
  }

  Widget _buildEntryMoreButton(_BrowsedFile file) {
    final l10n = AppLocalizations.of(context);
    return PopupMenuButton<Object>(
      icon: const Icon(Icons.more_horiz, size: 18),
      enabled: !_busy,
      position: PopupMenuPosition.under,
      onSelected: (action) => _handleEntryAction(file, action),
      itemBuilder: (_) => _entryActionItems(l10n),
    );
  }

  /// 移动端长按：底部菜单（无行内「更多」按钮）。
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
            for (final item in _entryActionItems(l10n))
              if (item is PopupMenuItem<Object>)
                ListTile(
                  title: item.child,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _handleEntryAction(file, item.value);
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
    // 全平台本地按文件名模糊搜索；不依赖 NAS/master。
    final onSpaceTab = _tabs.index == 1;
    final spaceFilter = onSpaceTab ? _navSpace : null;
    final pathPrefix =
        (onSpaceTab && _navSpace != null && _navPath.isNotEmpty)
            ? '$_navPath/'
            : '';
    await showSearch<void>(
      context: context,
      delegate: _LocalFileSearchDelegate(
        files: _files,
        space: spaceFilter,
        pathPrefix: pathPrefix,
        onOpen: _pickMode ? _togglePick : _previewFile,
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

  String _displayFileName(AppLocalizations l10n, _BrowsedFile file) {
    return StoreFileVisual.displayName(l10n, file.path);
  }

  Widget _buildFileAvatar(_BrowsedFile file) {
    return StoreFileListAvatar(
      deviceId: _targetId,
      space: file.space,
      path: file.path,
      sizeBytes: file.size,
    );
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
      actions: [
        if (_pickMode) ..._pickModeActions(l10n),
        if (!_pickMode && !_isRemote)
          IconButton(
            onPressed: _busy ? null : _openSearch,
            icon: const Icon(Icons.search),
            tooltip: l10n.storage_browserSearchTitle,
          ),
        if (!_pickMode)
          ..._buildMobileActions(l10n, includeCreate: !_readOnly),
      ],
    );
  }

  PreferredSizeWidget _buildMobileAppBar(AppLocalizations l10n) {
    return AppBar(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      title: _buildTabHeader(l10n),
      actions: [
        if (_pickMode) ..._pickModeActions(l10n),
        if (!_pickMode) ..._buildMobileActions(l10n, includeCreate: _mobileMineWritable(context)),
      ],
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
        if (_pickMode) ..._pickModeActions(l10n),
        if (!_pickMode && !_isRemote)
          IconButton(
            onPressed: _busy ? null : _openSearch,
            icon: const Icon(Icons.search),
            tooltip: l10n.storage_browserSearchTitle,
          ),
        if (!_pickMode) ...?widget.extraActions,
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
        position: PopupMenuPosition.under,
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

  Widget _buildFileRow(
    _BrowsedFile file,
    AppLocalizations l10n, {
    bool useModified = false,
    bool showMoreButton = false,
  }) {
    final subtitle = useModified
        ? _fmtLastModified(file.mtimeMs, l10n)
        : _fmtRecentAccess(file.mtimeMs, l10n);
    final picked = _isPicked(file);
    final disabled = _pickMode && !picked && _atPickLimit;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: _busy || disabled ? null : () => _onFileTap(file),
      onLongPress: _busy || _pickMode || showMoreButton
          ? null
          : () => _showEntryActions(file),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildFileAvatar(file),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _displayFileName(l10n, file),
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
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ],
              ),
            ),
            if (_pickMode) ...[
              const SizedBox(width: 8),
              Icon(
                picked ? Icons.check_circle : Icons.circle_outlined,
                color: picked ? scheme.primary : scheme.outline,
              ),
            ] else if (showMoreButton) ...[
              const SizedBox(width: 4),
              _buildEntryMoreButton(file),
            ],
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
    return ListView.separated(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: _files.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (context, i) => _buildFileRow(
        _files[i],
        l10n,
        showMoreButton: !mobile && !_pickMode,
      ),
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
          _buildFileRow(f, l10n, useModified: true),
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
                  padding: const EdgeInsets.only(top: 4, bottom: 16),
                  children: [
                    for (final name in children.folders)
                      ListTile(
                        leading: SizedBox(
                          width: 42,
                          child: Center(child: _buildFolderIcon()),
                        ),
                        title: Text(name),
                        trailing: const Icon(Icons.chevron_right, size: 20),
                        onTap: () => _enterFolder(name),
                      ),
                    for (final f in children.files)
                      _buildFileRow(
                        f,
                        l10n,
                        useModified: true,
                        showMoreButton: !_pickMode,
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
            leading: SizedBox(
              width: 42,
              child: Center(child: _buildFolderIcon()),
            ),
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

class _LocalFileSearchDelegate extends SearchDelegate<void> {
  _LocalFileSearchDelegate({
    required this.files,
    required this.space,
    required this.pathPrefix,
    required this.onOpen,
  });

  final List<_BrowsedFile> files;

  /// null = 不限分区（「最近」或 store 根）。
  final String? space;
  final String pathPrefix;
  final void Function(_BrowsedFile file) onOpen;

  /// 子序列模糊：needle 各字符按序出现在 text 中即可。
  static bool _fuzzySubsequence(String text, String needle) {
    if (needle.isEmpty) return true;
    var i = 0;
    for (final c in text.codeUnits) {
      if (c == needle.codeUnitAt(i)) {
        i++;
        if (i >= needle.length) return true;
      }
    }
    return false;
  }

  /// 越高越靠前；0 = 不匹配。
  static int _matchScore(String path, String needle) {
    final name = p.basename(path).toLowerCase();
    final full = path.toLowerCase();
    if (name == needle) return 500;
    if (name.startsWith(needle)) return 400;
    if (name.contains(needle)) return 300;
    if (_fuzzySubsequence(name, needle)) return 200;
    if (full.contains(needle)) return 100;
    if (_fuzzySubsequence(full, needle)) return 50;
    return 0;
  }

  List<_BrowsedFile> _matches(String q) {
    final needle = q.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final tokens =
        needle.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final scored = <(_BrowsedFile, int)>[];
    for (final f in files) {
      if (space != null && f.space != space) continue;
      if (pathPrefix.isNotEmpty && !f.path.startsWith(pathPrefix)) continue;
      if (p.basename(f.path) == _StorageBrowserScreenState._folderMarker) {
        continue;
      }
      var score = 0;
      var ok = true;
      for (final token in tokens) {
        final s = _matchScore(f.path, token);
        if (s <= 0) {
          ok = false;
          break;
        }
        score += s;
      }
      if (ok) scored.add((f, score));
    }
    scored.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      if (byScore != 0) return byScore;
      return b.$1.mtimeMs.compareTo(a.$1.mtimeMs);
    });
    return [for (final e in scored) e.$1];
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
          subtitle: Text(
            '${f.space}/${f.path}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () {
            close(context, null);
            onOpen(f);
          },
        );
      },
    );
  }
}
