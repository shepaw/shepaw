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

class _PouchScopeBrowserScreenState extends State<PouchScopeBrowserScreen> {
  final _scopes = <PouchScope>[];
  bool _loadingScopes = true;

  /// 顶层列 scope 失败的原因（带错误码）；固定四个分区照常显示。
  String? _scopesError;

  PouchScope? _scope;

  /// 宽屏左栏宽度（可拖拽），和玉简页保持一致。
  double _listPaneWidth = 280;
  static const double _minListPaneWidth = 220;
  static const double _maxListPaneWidth = 480;
  static const double _minDetailPaneWidth = 360;
  String _path = '';
  List<StoreEntry> _entries = const <StoreEntry>[];
  bool _loadingEntries = false;

  /// 上传/删除进行中：挡住重复操作。
  bool _busy = false;
  String? _error;

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
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _messageFor(e);
        _loadingEntries = false;
      });
    }
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
      _backToTop();
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
    final title = scope == null
        ? (widget.title ?? l10n.storage_scopeTitle)
        : _titleFor(scope);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = _wideFor(context, constraints);
        // 宽屏两栏：左边常驻 scope 列表，右边是当前 scope 的内容，和玉简页
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
                      child: _buildScopeListPane(),
                    ),
                    _buildPaneSplitter(constraints.maxWidth),
                    Expanded(
                      child: scope == null
                          ? _buildPickScopeHint(l10n)
                          : _buildScope(scope),
                    ),
                  ],
                )
              : (scope == null ? _buildScopeListPane() : _buildScope(scope)),
          floatingActionButton: scope == null
              ? null
              : FloatingActionButton.small(
                  tooltip: l10n.storage_upload,
                  onPressed: _busy ? null : _uploadFiles,
                  child: const Icon(Icons.file_upload_outlined),
                ),
        );
      },
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

  String _titleFor(PouchScope scope) {
    final name = _path.isEmpty ? '' : ' / ${_path.split('/').last}';
    return '${scope.displayName}$name';
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

  Widget _buildScope(PouchScope scope) {
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
    if (_entries.isEmpty) {
      // 空态：这一层确实没有条目（读失败走上面的 error 分支，带错误码）。
      return Padding(
        padding: const EdgeInsets.all(24),
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
      );
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
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
