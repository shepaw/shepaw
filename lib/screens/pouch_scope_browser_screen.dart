import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import '../utils/layout_utils.dart';
import '../services/store_open_service.dart';
import '../storage/group_shared_files.dart';
import '../storage/local_store.dart';
import '../storage/pouch_scope.dart';
import '../storage/pouch_scope_store.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';

/// 最小可用的 scope 浏览器（G4 / B 4.5）。
///
/// 第一层列 [PouchScope.fixed]（pouch/system/public/files）+ 调用方给的
/// agent/group/skill/slip scope；进到某个 scope 后按文件夹逐层列下一级。
/// 文件可以点开（预览/系统打开）、上传到当前目录、删除；不做拖拽/搜索。
/// 群共享面的写操作统一走 [GroupSharedFiles]。
class PouchScopeBrowserScreen extends StatefulWidget {
  const PouchScopeBrowserScreen({
    super.key,
    this.extraScopes = const <PouchScope>[],
    this.scopeLoader,
    this.store,
    this.title,
    this.initialScope,
    this.lockToInitialScope = false,
    this.initialPath = '',
    this.onOpenLegacy,
    this.sharedFiles,
  });

  /// 固定四个之外的 scope（群、助手、技能、玉简…）。
  final List<PouchScope> extraScopes;

  /// 进页面时补一批 scope（群列表之类）；失败忽略，不影响固定分区。
  final Future<List<PouchScope>> Function()? scopeLoader;

  /// 测试注入；null 时用 [StoreService.instance]。
  final PouchScopeStore? store;

  final String? title;

  /// 进来直接打开这个 scope（群会话的「文件」入口用它）；null 时停在顶层。
  final PouchScope? initialScope;

  /// 左栏只列 [initialScope] 这一个，不给切到别的空间。
  ///
  /// 一级「文件」入口用它：文件是用户自己的空间，不该从里面翻到群或
  /// 智能体的空间。为 false 时左栏列出全部 scope。
  final bool lockToInitialScope;

  /// 配合 [initialScope] 的起始路径。
  final String initialPath;

  /// 「旧数据（space 目录）」入口：给调用方决定怎么退回 v2 的浏览页。
  ///
  /// 为 null 时不显示这一项（例如群会话里没有可退的地方）。
  final VoidCallback? onOpenLegacy;

  /// 群共享面的写入口；null 时用 [GroupSharedFiles.resolve]。
  ///
  /// 共享文件的读写都走它（`files/` 前缀、版本号在那里统一处理），
  /// 浏览器不另开一条直接写 scope 的通路。
  final GroupSharedFiles? sharedFiles;

  /// 上传落点：进了子目录就传当前目录；在 scope 根按 v3 布局选约定目录
  /// （玉简 `files/`、会话 `attachments/`、助手 `files/attachments/`），
  /// 免得往 scope 根丢散文件。群共享的 `files/` 前缀由 [GroupSharedFiles]
  /// 自己加，这里保持根路径。
  static String uploadDirFor(PouchScope scope, String currentPath) {
    final path = currentPath.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (path.isNotEmpty) return path;
    return switch (scope.kind) {
      PouchScopeKind.slip => 'files',
      PouchScopeKind.session => 'attachments',
      PouchScopeKind.agent => 'files/attachments',
      _ => '',
    };
  }

  @override
  State<PouchScopeBrowserScreen> createState() =>
      _PouchScopeBrowserScreenState();
}

/// 锁定模式（一级「文件」入口）下左栏选中的那一项。
enum _FilesNav {
  /// 当前 scope 的目录列表。
  all,

  /// 这个 scope 里最近改过的文件。
  recent,
}

class _PouchScopeBrowserScreenState extends State<PouchScopeBrowserScreen> {
  final _scopes = <PouchScope>[];
  bool _loadingScopes = true;

  /// 顶层列 scope 失败的原因（带错误码）；固定四个分区照常显示。
  String? _scopesError;

  PouchScope? _scope;

  /// 当前 scope 根目录下的一层文件夹（锁定模式左栏的快捷入口）。
  ///
  /// 只存一层：更深的地方靠右栏路径栏走，不在这里展开树。
  List<StoreEntry> _rootFolders = const <StoreEntry>[];

  /// 宽屏左栏宽度（可拖拽），和玉简页保持一致。
  double _listPaneWidth = 280;
  static const double _minListPaneWidth = 220;
  static const double _maxListPaneWidth = 480;
  static const double _minDetailPaneWidth = 360;

  /// 窄屏根目录上那一节「最近」显示几条。
  static const int _recentStripCount = 5;

  /// 「最近」视图最多列几条。
  static const int _recentLimit = 50;

  String _path = '';
  List<StoreEntry> _entries = const <StoreEntry>[];
  bool _loadingEntries = false;

  /// 锁定模式左栏选中的那一项。
  _FilesNav _nav = _FilesNav.all;

  /// 这个 scope 里最近改过的文件（新→旧）。
  List<StoreEntry> _recentFiles = const <StoreEntry>[];
  bool _loadingRecent = false;
  String? _recentError;

  /// 上传/删除进行中：挡住重复操作。
  bool _busy = false;
  String? _error;

  /// 左栏是「最近 / 全部文件 / 文件夹」导航，而不是 scope 名单。
  ///
  /// 只在锁定到一个 scope 时成立：储物袋、群会话这些入口仍然要能在
  /// scope 之间切，行为不变。
  bool get _lockedNav => widget.lockToInitialScope;

  bool get _showRecent => _lockedNav && _nav == _FilesNav.recent;

  /// 还在子目录里：系统返回先往上走一级，不直接关掉整页。
  bool get _inSubfolder => _scope != null && _path.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadScopes();
  }

  Future<void> _loadScopes() async {
    final found = <PouchScope>[...PouchScope.fixed, ...widget.extraScopes];
    String? failure;
    try {
      // hub 按前缀列 scope（op=scopes）：固定四个之外，agent/group/skill/
      // instruction/slip 的 id 都从袋子里来，不再靠本地库猜。
      final store = await _store();
      final ids = await store.scopes('');
      for (final id in ids) {
        final parsed = PouchScope.tryParse(id);
        if (parsed == null || !_listedAtTop(parsed)) continue;
        found.add(parsed);
      }
    } catch (e) {
      // 读不到（未配对 / 连不上 / 没权限）不是「空」：把错误码显示出来。
      failure = _messageFor(e);
    }
    try {
      final extra = await widget.scopeLoader?.call();
      if (extra != null) found.addAll(extra);
    } catch (_) {
      // 名单拿不到就只显示上面那批。
    }
    if (!mounted) return;
    setState(() {
      _scopes
        ..clear()
        ..addAll({for (final scope in found) scope.id: scope}.values);
      _scopesError = failure;
      _loadingScopes = false;
    });
    final initial = widget.initialScope;
    if (initial != null) {
      await _openScope(initial, path: widget.initialPath);
    }
  }

  /// 顶层只列「可以直接点进去看文件」的 scope：
  /// 固定四个 + agent 根 + 群根 + 群共享 + 技能/指令/玉简。
  /// 会话、任务、成员这些由各自的功能入口进（群会话面板、任务页），
  /// 否则群一多顶层就被会话淹没。
  bool _listedAtTop(PouchScope scope) => switch (scope.kind) {
        PouchScopeKind.session ||
        PouchScopeKind.task ||
        PouchScopeKind.member =>
          false,
        _ => true,
      };

  Future<PouchScopeStore> _store() async =>
      widget.store ?? await StoreService.instance.scopeStore();

  Future<void> _openScope(PouchScope scope, {String path = ''}) async {
    setState(() {
      _scope = scope;
      _path = path;
      _entries = const [];
      _error = null;
      _loadingEntries = true;
    });
    try {
      final store = await _store();
      final entries = await store.listChildren(scope, path: path);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loadingEntries = false;
        if (path.isEmpty) {
          _rootFolders = entries.where((entry) => entry.isDir).toList();
        }
      });
      // 回到根目录时顺手刷新「最近」：刚传上来、刚删掉的文件要体现出来。
      if (_lockedNav && path.isEmpty) unawaited(_loadRecent(scope));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _messageFor(e);
        _loadingEntries = false;
      });
    }
  }

  /// 这个 scope 里最近改过的文件（按 mtime，v3 里没有访问记录）。
  Future<void> _loadRecent(PouchScope scope) async {
    setState(() {
      _loadingRecent = true;
      _recentError = null;
    });
    try {
      final store = await _store();
      final files = await store.recentFiles(scope, limit: _recentLimit);
      if (!mounted) return;
      setState(() {
        _recentFiles = files;
        _loadingRecent = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _recentError = _messageFor(e);
        _loadingRecent = false;
      });
    }
  }

  /// 左栏选「最近」或「全部文件」。
  void _selectNav(_FilesNav nav) {
    final scope = _scope;
    if (scope == null) return;
    setState(() => _nav = nav);
    if (nav == _FilesNav.recent) {
      unawaited(_loadRecent(scope));
    } else if (_path.isNotEmpty) {
      unawaited(_openScope(scope));
    }
  }

  /// 左栏点某个文件夹：切回目录视图并进到那一层。
  void _openFolder(StoreEntry folder) {
    final scope = _scope;
    if (scope == null) return;
    setState(() => _nav = _FilesNav.all);
    _openScope(scope, path: folder.path);
  }

  /// 读失败时给人的话 + 错误码。空列表和读不到必须能分开：前者是数据状态，
  /// 后者要让用户看见是哪一类失败（未配对 / 离线 / 无权限…）。
  String _messageFor(Object error) {
    if (error is StoreException) {
      final hint = switch (error.code) {
        StoreError.notPaired => '还没有登录袋子',
        StoreError.masterOffline => '连不上这台主机',
        StoreError.notFound => '这个位置不存在',
        StoreError.crossPouchDenied => '这个地址属于另一只袋子',
        StoreError.aclDenied => '没有权限看这里',
        StoreError.versionConflict => '内容已经被别人改过',
        StoreError.badScope => 'scope 不合法',
        _ => '读取失败',
      };
      final code = error.code.trim();
      return code.isEmpty ? hint : '$hint（$code）';
    }
    return '读取失败：$error';
  }

  void _backToTop() {
    setState(() {
      _scope = null;
      _path = '';
      _entries = const [];
      _error = null;
    });
  }

  void _enterDirectory(StoreEntry entry) {
    final scope = _scope;
    if (scope == null) return;
    _openScope(scope, path: entry.path);
  }

  void _upOneLevel() {
    final scope = _scope;
    if (scope == null) return;
    if (_path.isEmpty) {
      // 锁在 files 上时根目录就是底：退出交给路由返回，不再退到 scope 名单
      // （那份名单只有一个 files，退过去等于原地打转）。
      if (_lockedNav) {
        unawaited(Navigator.maybePop(context));
      } else {
        _backToTop();
      }
      return;
    }
    final slash = _path.lastIndexOf('/');
    _openScope(scope, path: slash < 0 ? '' : _path.substring(0, slash));
  }

  Future<GroupSharedFiles> _shared() async =>
      widget.sharedFiles ?? await GroupSharedFiles.resolve();

  /// 点文件：交给 [StoreOpenService]（图片/文本直接预览，其余物化后系统打开）。
  Future<void> _openFile(PouchScope scope, StoreEntry entry) async {
    final store = await _store();
    final uri = store.uriFor(scope, entry.path).format();
    if (!mounted) return;
    await StoreOpenService.instance.openStoreUri(context, uri);
  }

  /// 往当前目录传文件；重名自动加 ` (1)`，不覆盖已有文件。
  Future<void> _uploadFiles() async {
    final scope = _scope;
    if (scope == null || _busy) return;
    final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (picked == null || picked.files.isEmpty) return;
    if (!mounted) return;
    setState(() => _busy = true);
    final failures = <String>[];
    final dir = PouchScopeBrowserScreen.uploadDirFor(scope, _path);
    var uploaded = 0;
    try {
      final taken = {for (final entry in _entries) entry.path.split('/').last};
      for (final item in picked.files) {
        final localPath = item.path;
        if (localPath == null) continue;
        final file = File(localPath);
        if (!await file.exists()) continue;
        final name = _uniqueName(p.basename(localPath), taken);
        taken.add(name);
        final path = dir.isEmpty ? name : '$dir/$name';
        try {
          await _writeBytes(scope, path, await file.readAsBytes());
          uploaded++;
        } catch (e) {
          failures.add('$name：${_messageFor(e)}');
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (failures.isEmpty) {
      _toast('已上传 $uploaded 个文件');
    } else {
      _toast('上传失败——${failures.join('；')}');
    }
    await _openScope(scope, path: _path);
  }

  /// 写一份文件：群共享面只有 [GroupSharedFiles] 一个入口，其余直接写 scope。
  Future<void> _writeBytes(
    PouchScope scope,
    String path,
    Uint8List bytes,
  ) async {
    if (scope.kind == PouchScopeKind.shared) {
      await (await _shared()).write(scope.ownerId, path, bytes);
      return;
    }
    await (await _store()).write(scope, path, bytes);
  }

  Future<void> _deleteEntry(PouchScope scope, StoreEntry entry) async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context);
    final name = entry.path.split('/').last;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.storage_deleteFileTitle),
        content: Text(l10n.storage_deleteFileConfirm(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.common_delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      if (scope.kind == PouchScopeKind.shared) {
        await (await _shared()).delete(scope.ownerId, entry.path);
      } else {
        await (await _store()).delete(scope, entry.path);
      }
      if (mounted) _toast('已删除 $name');
    } catch (e) {
      if (mounted) _toast('删除失败——${_messageFor(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _openScope(scope, path: _path);
    // 从「最近」里删的时候当前目录不一定刷得到那一条，单独再取一次。
    if (_lockedNav && _showRecent) await _loadRecent(scope);
  }

  /// 同目录重名时依次试 `name (1).ext`、`name (2).ext`…
  static String _uniqueName(String name, Set<String> taken) {
    if (!taken.contains(name)) return name;
    final ext = p.extension(name);
    final base = ext.isEmpty ? name : name.substring(0, name.length - ext.length);
    for (var i = 1;; i++) {
      final candidate = '$base ($i)$ext';
      if (!taken.contains(candidate)) return candidate;
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scope = _scope;
    final title = _titleFor(l10n, scope);
    return PopScope<Object?>(
      // 还在子目录里时，系统返回先往上走一级，不直接关掉整页。
      canPop: !_inSubfolder,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _upOneLevel();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = _wideFor(context, constraints);
          // 宽屏两栏：左边常驻列表，右边是当前 scope 的内容，和玉简页
          // 一个布局。窄屏仍是「顶层列表 → 点进 scope」的两级导航。
          return Scaffold(
            appBar: AppBar(
              elevation: 0,
              scrolledUnderElevation: 0,
              title: Text(title),
              leading: (wide || scope == null)
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip:
                          MaterialLocalizations.of(context).backButtonTooltip,
                      onPressed: _upOneLevel,
                    ),
            ),
            body: wide
                ? Row(
                    children: [
                      SizedBox(
                        width: _listPaneWidth,
                        child: _lockedNav
                            ? _buildFilesNavPane(l10n)
                            : _buildScopeListPane(),
                      ),
                      _buildPaneSplitter(constraints.maxWidth),
                      Expanded(
                        child: scope == null
                            ? _buildPickScopeHint(l10n)
                            : _buildContent(l10n, scope, wide: true),
                      ),
                    ],
                  )
                : (scope == null
                    ? _buildScopeListPane()
                    : _buildContent(l10n, scope, wide: false)),
            floatingActionButton: scope == null || _showRecent
                ? null
                : FloatingActionButton.small(
                    tooltip: l10n.storage_upload,
                    onPressed: _busy ? null : _uploadFiles,
                    child: const Icon(Icons.file_upload_outlined),
                  ),
          );
        },
      ),
    );
  }

  /// 右栏：上面一条路径栏，下面是目录列表或「最近」。
  Widget _buildContent(
    AppLocalizations l10n,
    PouchScope scope, {
    required bool wide,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPathBar(l10n, scope),
        Expanded(
          child: _showRecent
              ? _buildRecentView(l10n, scope)
              : _buildEntries(l10n, scope, wide: wide),
        ),
      ],
    );
  }

  /// 路径栏：返回按钮 + 可点的路径（`文件 / 项目资料 / 2026`）。
  ///
  /// 进了子目录以后这是主要的回退入口——宽屏没有标题栏返回键，只点左栏的
  /// scope 名也只能回到根。
  Widget _buildPathBar(AppLocalizations l10n, PouchScope scope) {
    final segments = <({String label, VoidCallback? onTap})>[
      (
        label: scope.displayName,
        // 在「最近」视图里，根这一段就是回到全部文件的入口。
        onTap: _showRecent
            ? () => _selectNav(_FilesNav.all)
            : (_path.isEmpty ? null : () => _openScope(scope)),
      ),
    ];
    final parts = _path.split('/').where((part) => part.isNotEmpty).toList();
    var acc = '';
    for (var i = 0; i < parts.length; i++) {
      acc = acc.isEmpty ? parts[i] : '$acc/${parts[i]}';
      final target = acc;
      segments.add((
        label: parts[i],
        onTap:
            i == parts.length - 1 ? null : () => _openScope(scope, path: target),
      ));
    }
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 18),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: _path.isEmpty ? null : _upOneLevel,
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < segments.length; i++) ...[
                      if (i > 0)
                        Text(
                          ' / ',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: muted),
                        ),
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

  bool _wideFor(BuildContext context, BoxConstraints constraints) =>
      LayoutUtils.isDesktopLayout(context) && constraints.maxWidth >= 720;

  void _resizeListPane(double delta, double maxWidth) {
    final room = maxWidth - _minDetailPaneWidth;
    final maxList = room < _minListPaneWidth
        ? _minListPaneWidth
        : (room > _maxListPaneWidth ? _maxListPaneWidth : room);
    final next = _listPaneWidth + delta;
    setState(() {
      _listPaneWidth = next < _minListPaneWidth
          ? _minListPaneWidth
          : (next > maxList ? maxList : next);
    });
  }

  Widget _buildPaneSplitter(double maxWidth) {
    final line = Theme.of(context).colorScheme.outline;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) =>
          _resizeListPane(details.delta.dx, maxWidth),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: SizedBox(
          width: 8,
          child: Center(
            child: Container(width: 1, color: line),
          ),
        ),
      ),
    );
  }

  /// 宽屏左边还没选 scope 时的提示。
  Widget _buildPickScopeHint(AppLocalizations l10n) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.folder_open_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.storage_pickScopeHint,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  String _titleFor(AppLocalizations l10n, PouchScope? scope) {
    if (scope == null) return widget.title ?? l10n.storage_scopeTitle;
    if (_showRecent) return l10n.storage_recentTitle;
    final name = _path.isEmpty ? '' : ' / ${_path.split('/').last}';
    return '${scope.displayName}$name';
  }

  /// 锁定模式（一级「文件」入口）的左栏：最近 / 全部文件 / 根目录下的文件夹。
  ///
  /// 这一栏不再列 scope 名单——锁在 files 上时那份名单只有一项，留着只会
  /// 让人以为还能切到别处。
  Widget _buildFilesNavPane(AppLocalizations l10n) {
    final primary = Theme.of(context).colorScheme.primary;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        ListTile(
          leading: const Icon(Icons.history_outlined),
          title: Text(l10n.storage_spaceRecent),
          selected: _nav == _FilesNav.recent,
          onTap: () => _selectNav(_FilesNav.recent),
        ),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(l10n.storage_filesAllFiles),
          selected: _nav == _FilesNav.all && _path.isEmpty,
          onTap: () => _selectNav(_FilesNav.all),
        ),
        if (_rootFolders.isNotEmpty) ...[
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              l10n.storage_filesFolders,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: primary),
            ),
          ),
          for (final folder in _rootFolders)
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: Text(folder.path.split('/').last),
              selected: _nav == _FilesNav.all && _path == folder.path,
              onTap: () => _openFolder(folder),
            ),
        ],
        if (widget.onOpenLegacy != null) ...[
          const Divider(height: 24),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: Text(l10n.storage_legacyData),
            subtitle: Text(l10n.storage_legacyDataSub),
            trailing: const Icon(Icons.chevron_right),
            onTap: widget.onOpenLegacy,
          ),
        ],
      ],
    );
  }

  Widget _buildScopeListPane() {
    final l10n = AppLocalizations.of(context);
    if (_loadingScopes) {
      return const Center(child: CircularProgressIndicator());
    }
    final locked = widget.lockToInitialScope ? widget.initialScope : null;
    final visible = locked == null
        ? _scopes
        : _scopes.where((scope) => scope.id == locked.id).toList();
    final groups = groupPouchScopes(visible);
    // 已经进到某个 scope 时，名单读不到不再占左栏顶部报错——用户看的是
    // 右边内容，那里的错误才是主信息（宽屏两栏下免得同一句报两遍）。
    final scopesError = _scope == null ? _scopesError : null;
    return ListView(
      children: [
        if (scopesError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      scopesError,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _loadingScopes ? null : _reloadScopes,
                    child: Text(l10n.common_retry),
                  ),
                ],
              ),
            ),
          ),
        for (final group in groups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              group.label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              group.subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          for (final scope in group.scopes)
            ListTile(
              selected: _scope?.id == scope.id,
              leading: Icon(_iconFor(scope.kind)),
              title: Text(scope.displayName),
              subtitle: Text(scope.id),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openScope(scope),
            ),
        ],
        if (widget.onOpenLegacy != null) ...[
          const Divider(height: 24),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: Text(l10n.storage_legacyData),
            subtitle: Text(l10n.storage_legacyDataSub),
            trailing: const Icon(Icons.chevron_right),
            onTap: widget.onOpenLegacy,
          ),
        ],
      ],
    );
  }

  void _reloadScopes() {
    setState(() {
      _loadingScopes = true;
      _scopesError = null;
    });
    _loadScopes();
  }

  /// 目录列表。窄屏且停在根目录时，上面带一节「最近」。
  Widget _buildEntries(
    AppLocalizations l10n,
    PouchScope scope, {
    required bool wide,
  }) {
    if (_loadingEntries) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(error, textAlign: TextAlign.center),
        ),
      );
    }
    // 宽屏的「最近」在左栏有入口，不在这里再摆一遍。
    final strip = (_lockedNav && _path.isEmpty && !wide)
        ? _buildRecentStrip(l10n, scope)
        : null;
    if (_entries.isEmpty) {
      // 空态：这一层确实没有条目（读失败走上面的 error 分支，带错误码）。
      final empty = Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.folder_open_outlined,
                size: 40,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 8),
              Text(
                '这个位置还没有文件',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
      if (strip == null) return empty;
      return Column(
        children: [strip, Expanded(child: empty)],
      );
    }
    final offset = strip == null ? 0 : 1;
    return ListView.builder(
      itemCount: _entries.length + offset,
      itemBuilder: (context, index) {
        if (strip != null && index == 0) return strip;
        final entry = _entries[index - offset];
        final name = entry.path.split('/').last;
        return ListTile(
          leading: Icon(
            entry.isDir ? Icons.folder_outlined : Icons.description_outlined,
          ),
          title: Text(name),
          subtitle: entry.isDir ? null : Text(_formatSize(entry.size)),
          onTap: entry.isDir
              ? () => _enterDirectory(entry)
              : () => _openFile(scope, entry),
          trailing: entry.isDir
              ? null
              : IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '删除',
                  onPressed: _busy ? null : () => _deleteEntry(scope, entry),
                ),
        );
      },
    );
  }

  /// 窄屏根目录顶部那一节「最近」。
  Widget _buildRecentStrip(AppLocalizations l10n, PouchScope scope) {
    final items = _recentFiles.take(_recentStripCount).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              Icon(
                Icons.history_outlined,
                size: 16,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                l10n.storage_spaceRecent,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => _selectNav(_FilesNav.recent),
                child: Text(l10n.storage_recentViewAll),
              ),
            ],
          ),
        ),
        if (_loadingRecent && items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          ),
        if (!_loadingRecent && items.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              l10n.storage_recentEmpty,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        for (final item in items) _buildRecentTile(l10n, scope, item),
        const Divider(height: 16),
      ],
    );
  }

  /// 整个 scope 里最近改过的文件（宽屏左栏「最近」、窄屏「查看全部」）。
  Widget _buildRecentView(AppLocalizations l10n, PouchScope scope) {
    if (_loadingRecent) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _recentError;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(error, textAlign: TextAlign.center),
        ),
      );
    }
    if (_recentFiles.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.history_toggle_off_outlined,
              size: 40,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.storage_recentEmpty,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return ListView(
      children: [
        for (final item in _recentFiles) _buildRecentTile(l10n, scope, item),
      ],
    );
  }

  /// 「最近」里的文件：文件名 + 所在文件夹 + 时间。
  Widget _buildRecentTile(
    AppLocalizations l10n,
    PouchScope scope,
    StoreEntry entry,
  ) {
    final name = entry.path.split('/').last;
    final dir = p.dirname(entry.path);
    final parts = <String>[dir.isEmpty ? scope.displayName : dir.split('/').last];
    final stamp = _formatStamp(entry.mtimeMs);
    if (stamp.isNotEmpty) parts.add(stamp);
    return ListTile(
      leading: const Icon(Icons.description_outlined),
      title: Text(name),
      subtitle: Text(parts.join(' · ')),
      onTap: () => _openFile(scope, entry),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: '删除',
        onPressed: _busy ? null : () => _deleteEntry(scope, entry),
      ),
    );
  }

  /// `10月30日 14:05` / `10/30 14:05`；mtime 为 0（hub 没给）时留空。
  String _formatStamp(int mtimeMs) {
    if (mtimeMs <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(mtimeMs).toLocal();
    final time =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (Localizations.localeOf(context).languageCode == 'zh') {
      return '${t.month}月${t.day}日 $time';
    }
    return '${t.month}/${t.day} $time';
  }

  IconData _iconFor(PouchScopeKind kind) => switch (kind) {
        PouchScopeKind.pouch => Icons.inventory_2_outlined,
        PouchScopeKind.system => Icons.settings_outlined,
        PouchScopeKind.public => Icons.public,
        PouchScopeKind.files => Icons.folder_outlined,
        PouchScopeKind.group => Icons.groups_outlined,
        PouchScopeKind.shared => Icons.folder_shared_outlined,
        PouchScopeKind.member => Icons.person_outline,
        PouchScopeKind.session => Icons.forum_outlined,
        PouchScopeKind.task => Icons.task_alt_outlined,
        PouchScopeKind.agent => Icons.smart_toy_outlined,
        PouchScopeKind.skill => Icons.auto_awesome_outlined,
        PouchScopeKind.instruction => Icons.menu_book_outlined,
        PouchScopeKind.slip => Icons.sticky_note_2_outlined,
      };

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
