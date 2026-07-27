import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../storage/device_identity.dart';
import '../storage/local_store.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';

/// 按设备 / 分区浏览 store 正式文件并手删（方案 §7.3）。
///
/// 本机始终可浏览自身目录；master 可浏览磁盘上他端镜像并删除（进回收站）。
/// 仅读本地 [LocalStore]，不经远端 list。
class StorageBrowserScreen extends StatefulWidget {
  const StorageBrowserScreen({super.key});

  @override
  State<StorageBrowserScreen> createState() => _StorageBrowserScreenState();
}

class _StorageBrowserScreenState extends State<StorageBrowserScreen> {
  static const _pageStep = 100;

  String _selfId = '';
  String _masterId = '';
  String _deviceId = '';
  String _space = StoreSpace.files;
  String _prefix = '';
  int _limit = _pageStep;
  bool _busy = false;
  bool _loading = true;
  List<String> _devices = const [];
  List<StoreEntry> _entries = const [];
  String? _error;

  bool get _isMaster => _masterId == _selfId && _selfId.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final self = await DeviceIdentity.deviceId();
    final master = await StoreService.instance.masterDeviceId();
    final store = await StoreService.instance.localStore();
    final stats = await store.stats();
    final devicesMap =
        (stats['devices'] as Map?)?.cast<String, dynamic>() ?? {};
    final devices = <String>{self, ...devicesMap.keys}.toList()..sort();
    if (!mounted) return;
    setState(() {
      _selfId = self;
      _masterId = master;
      _deviceId = self;
      _devices = devices;
    });
    await _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final store = await StoreService.instance.localStore();
      final entries = await store.list(
        _deviceId,
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

  bool _canDelete(String deviceId) {
    if (deviceId == _selfId) return true;
    return _isMaster;
  }

  Future<void> _deleteEntry(StoreEntry entry) async {
    final l10n = AppLocalizations.of(context);
    if (!_canDelete(_deviceId)) {
      _toast(l10n.storage_browserDeleteDenied);
      return;
    }
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
      await store.delete(_deviceId, _space, entry.path);
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

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _shortDevice(String id) {
    if (id == _selfId) {
      final short = id.length >= 8 ? '${id.substring(0, 8)}…' : id;
      return '$short (${AppLocalizations.of(context).storage_thisDevice})';
    }
    return id.length >= 8 ? '${id.substring(0, 8)}…' : id;
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
    final selectableDevices = _isMaster
        ? _devices
        : _devices.where((d) => d == _selfId).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.storage_browserTitle),
        actions: [
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
                InputDecorator(
                  decoration: InputDecoration(
                    labelText: l10n.storage_browserDevice,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: selectableDevices.contains(_deviceId)
                          ? _deviceId
                          : (_selfId.isEmpty ? null : _selfId),
                      items: [
                        for (final id in selectableDevices)
                          DropdownMenuItem(
                            value: id,
                            child: Text(_shortDevice(id)),
                          ),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) {
                              if (v == null) return;
                              setState(() {
                                _deviceId = v;
                                _limit = _pageStep;
                              });
                              _reload();
                            },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final space in StoreSpace.all)
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
                      icon: const Icon(Icons.search),
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
                    final canDelete = _canDelete(_deviceId);
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
                      trailing: canDelete
                          ? IconButton(
                              icon: Icon(Icons.delete_outline,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.error),
                              onPressed:
                                  _busy ? null : () => _deleteEntry(e),
                              tooltip: l10n.storage_browserDelete,
                            )
                          : null,
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
