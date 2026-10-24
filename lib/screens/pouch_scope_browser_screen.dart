import 'package:flutter/material.dart';

import '../storage/local_store.dart';
import '../storage/pouch_scope.dart';
import '../storage/pouch_scope_store.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';

/// 最小可用的 scope 浏览器（G4 / B 4.5）。
///
/// 第一层列 [PouchScope.fixed]（pouch/system/public/files）+ 调用方给的
/// agent/group/skill/slip scope；进到某个 scope 后按文件夹逐层列下一级。
/// 不做拖拽/搜索等交互：只回答「这只袋子里有哪些 scope、某个 scope 下有什么」。
class PouchScopeBrowserScreen extends StatefulWidget {
  const PouchScopeBrowserScreen({
    super.key,
    this.extraScopes = const <PouchScope>[],
    this.scopeLoader,
    this.store,
    this.title,
    this.initialScope,
    this.initialPath = '',
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

  /// 配合 [initialScope] 的起始路径。
  final String initialPath;

  @override
  State<PouchScopeBrowserScreen> createState() =>
      _PouchScopeBrowserScreenState();
}

class _PouchScopeBrowserScreenState extends State<PouchScopeBrowserScreen> {
  final _scopes = <PouchScope>[];
  bool _loadingScopes = true;

  PouchScope? _scope;
  String _path = '';
  List<StoreEntry> _entries = const <StoreEntry>[];
  bool _loadingEntries = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadScopes();
  }

  Future<void> _loadScopes() async {
    final found = <PouchScope>[...PouchScope.fixed, ...widget.extraScopes];
    try {
      final extra = await widget.scopeLoader?.call();
      if (extra != null) found.addAll(extra);
    } catch (_) {
      // 名单拿不到就只显示固定分区。
    }
    if (!mounted) return;
    setState(() {
      _scopes
        ..clear()
        ..addAll({for (final scope in found) scope.id: scope}.values);
      _loadingScopes = false;
    });
    final initial = widget.initialScope;
    if (initial != null) {
      await _openScope(initial, path: widget.initialPath);
    }
  }

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

  String _messageFor(Object error) {
    if (error is StoreException) {
      return switch (error.code) {
        StoreError.notPaired => '还没有登录袋子',
        StoreError.masterOffline => '连不上这台主机',
        StoreError.notFound => '这里还没有文件',
        StoreError.crossPouchDenied => '这个地址属于另一只袋子',
        StoreError.aclDenied => '没有权限看这里',
        _ => '读取失败：${error.code}',
      };
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

  @override
  Widget build(BuildContext context) {
    final scope = _scope;
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
            scope == null ? (widget.title ?? '袋子 scope') : _titleFor(scope)),
        leading: scope == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: _upOneLevel,
              ),
      ),
      body: scope == null ? _buildTopLevel() : _buildScope(scope),
    );
  }

  String _titleFor(PouchScope scope) {
    final name = _path.isEmpty ? '' : ' / ${_path.split('/').last}';
    return '${scope.displayName}$name';
  }

  Widget _buildTopLevel() {
    if (_loadingScopes) {
      return const Center(child: CircularProgressIndicator());
    }
    final groups = groupPouchScopes(_scopes);
    return ListView(
      children: [
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
              leading: Icon(_iconFor(scope.kind)),
              title: Text(scope.displayName),
              subtitle: Text(scope.id),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openScope(scope),
            ),
        ],
      ],
    );
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
      return const Center(child: Text('这里还没有文件'));
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
          onTap: entry.isDir ? () => _enterDirectory(entry) : null,
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
