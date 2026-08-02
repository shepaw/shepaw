import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../storage/device_identity.dart';
import '../storage/local_store.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';

/// 浏览本机 App store 正式文件并手删（进回收站）。
///
/// 版本 / 血缘 / 搜索经 Noise 调 master（见 docs/APP_CONSUMER_UI.md）。
class StorageBrowserScreen extends StatefulWidget {
  const StorageBrowserScreen({super.key});

  @override
  State<StorageBrowserScreen> createState() => _StorageBrowserScreenState();
}

class _StorageBrowserScreenState extends State<StorageBrowserScreen> {
  static const _pageStep = 100;

  String _selfId = '';
  String _space = StoreSpace.files;
  String _prefix = '';
  int _limit = _pageStep;
  bool _busy = false;
  bool _loading = true;
  List<StoreEntry> _entries = const [];
  String? _error;

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

  Future<void> _deleteEntry(StoreEntry entry) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.storage_browserDeleteTitle),
        content: Text(l10n.storage_browserDeleteConfirm(entry.path)),
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
      await store.delete(_selfId, _space, entry.path);
      _toast(l10n.storage_browserDeleted(entry.path));
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

  Future<void> _showEntryActions(StoreEntry entry) async {
    final l10n = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(entry.path,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(_fmtBytes(entry.size)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.history),
              title: Text(l10n.storage_browserVersions),
              onTap: () {
                Navigator.of(ctx).pop();
                _showVersions(entry);
              },
            ),
            ListTile(
              leading: const Icon(Icons.account_tree_outlined),
              title: Text(l10n.storage_browserManifest),
              onTap: () {
                Navigator.of(ctx).pop();
                _showManifest(entry);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(ctx).colorScheme.error),
              title: Text(l10n.storage_browserDelete),
              onTap: () {
                Navigator.of(ctx).pop();
                _deleteEntry(entry);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showVersions(StoreEntry entry) async {
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
        space: _space,
        device: _selfId,
        path: entry.path,
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
                        final shaShort = sha.length >= 16
                            ? sha.substring(0, 16)
                            : sha;
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

  Future<void> _showManifest(StoreEntry entry) async {
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
        space: _space,
        device: _selfId,
        path: entry.path,
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
    if (await StoreService.instance.isMaster()) {
      if (!mounted) return;
      _toast(l10n.storage_browserNeedMaster);
      return;
    }
    if (!mounted) return;
    await showSearch<void>(
      context: context,
      delegate: _StoreSearchDelegate(space: _space),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.storage_browserTitle),
        actions: [
          IconButton(
            onPressed: _busy ? null : _openSearch,
            icon: const Icon(Icons.search),
            tooltip: l10n.storage_browserSearchTitle,
          ),
          IconButton(
            onPressed: _busy ? null : _reload,
            icon: const Icon(Icons.refresh),
            tooltip: l10n.storage_browserRefresh,
          ),
        ],
      ),
      body: _loading && _entries.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(l10n.storage_browserHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        )),
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
                    child: Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  )
                else if (_entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(l10n.storage_browserEmpty,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall),
                  )
                else ...[
                  Text(
                    l10n.storage_browserCount(_entries.length),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 4),
                  ..._entries.map((e) {
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: const Icon(Icons.insert_drive_file_outlined,
                          size: 18),
                      title: Text(e.path,
                          style: Theme.of(context).textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis),
                      subtitle: Text(_fmtBytes(e.size),
                          style: Theme.of(context).textTheme.labelSmall),
                      onTap: _busy ? null : () => _showEntryActions(e),
                      trailing: IconButton(
                        icon: Icon(Icons.delete_outline,
                            size: 18,
                            color: Theme.of(context).colorScheme.error),
                        onPressed: _busy ? null : () => _deleteEntry(e),
                        tooltip: l10n.storage_browserDelete,
                      ),
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
            final idx =
                i - ((degraded || scoreType.isNotEmpty) ? 1 : 0);
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
