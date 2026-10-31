import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../storage/device_identity.dart';
import '../storage/host_pouch_target.dart';
import '../storage/pouch_scope.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import 'pouch_scope_browser_screen.dart';
import 'storage_browser_screen.dart';
import 'storage_shared.dart';

/// 储物袋本机浏览页「更多」菜单动作。
enum StorageMoreAction {
  hideInternal,
}

/// 各空间「更多」只保留视图开关。用量、回收站、备份与恢复在储物袋顶级菜单。
List<PopupMenuEntry<StorageMoreAction>> storageMoreMenuItems(
  BuildContext context,
  AppLocalizations l10n, {
  bool hideInternalSelected = false,
}) {
  final muted = Theme.of(context).colorScheme.onSurfaceVariant;
  return [
    PopupMenuItem(
      value: StorageMoreAction.hideInternal,
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          Expanded(child: Text(l10n.storage_recentHideInternal)),
          if (hideInternalSelected)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Icon(Icons.check, size: 18, color: muted),
            ),
        ],
      ),
    ),
  ];
}

/// 储物袋：本机空间浏览（其他设备空间不在此进入）。
///
/// 未指定 [initialSpace] 时停在空间列表，顶部有几条「接着打开」。
/// 传入分区时直接进入该分区根目录。
class StorageSpaceManageScreen extends StatefulWidget {
  const StorageSpaceManageScreen({
    super.key,
    this.initialSpace,
  });

  /// 初始分区。null = 空间列表。
  final String? initialSpace;

  @override
  State<StorageSpaceManageScreen> createState() =>
      _StorageSpaceManageScreenState();
}

class _StorageSpaceManageScreenState extends State<StorageSpaceManageScreen> {
  int? _usedBytes;
  StreamSubscription<void>? _usageSub;
  HostPouchTarget? _pouch;

  /// 空间内是否隐藏内部记账文件；由本页「更多」菜单持有并下发给浏览页。
  bool _hideInternalFiles = true;

  /// 这只机器上有可用的 v3 袋子（登录过 / 本机 hub 有 active_pouch）。
  ///
  /// [G4]：有它就默认按 scope 浏览器，space/device 那套退到「旧数据」入口。
  bool _hasScopeStore = false;

  /// 用户主动点了「旧数据」：本次停在 space 浏览页。
  bool _forceLegacy = false;

  void _handleMoreAction(StorageMoreAction action) {
    switch (action) {
      case StorageMoreAction.hideInternal:
        setState(() => _hideInternalFiles = !_hideInternalFiles);
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_resolvePouch());
  }

  Future<void> _resolvePouch() async {
    final target = await HostPouchTarget.resolve();
    final scoped = await StoreService.instance.scopeStoreOrNull();
    if (!mounted) return;
    setState(() {
      _pouch = target;
      _hasScopeStore = scoped != null;
    });
    if (!target.isRemote) unawaited(_loadUsedBytes());
  }

  @override
  void dispose() {
    _usageSub?.cancel();
    super.dispose();
  }

  Future<void> _loadUsedBytes() async {
    try {
      final selfId = await DeviceIdentity.deviceId();
      final store = await StoreService.instance.localStore();
      _usageSub ??= store.usageUpdates.listen((_) {
        if (mounted) unawaited(_loadUsedBytes());
      });
      final stats = await store.stats(blocking: false);
      final total = storageDeviceUsedBytes(stats, selfId);
      if (!mounted) return;
      setState(() => _usedBytes = total);
    } catch (_) {
      // 用量 badge 失败时静默；文件列表仍可浏览。
    }
  }

  @override
  Widget build(BuildContext context) {
    final pouch = _pouch;
    if (pouch == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final l10n = AppLocalizations.of(context);
    final space = widget.initialSpace;
    // 主机现在只认 v3 的 scope 请求，v2 的 space/device 视图发过去会报
    // 「scope required」并只剩一个空页。所以只要袋子在，一律走 scope 浏览；
    // v2 留给「旧数据」入口（[onOpenLegacy]）自己退回去。
    if (_hasScopeStore && !_forceLegacy) {
      return PouchScopeBrowserScreen(
        title: space == null ? l10n.storage_title : storageSpaceLabel(l10n, space),
        initialScope: space == StoreSpace.files ? PouchScope.files : null,
        lockToInitialScope: space == StoreSpace.files,
        onOpenLegacy: space == null
            ? () => setState(() => _forceLegacy = true)
            : null,
      );
    }
    return StorageBrowserScreen(
      deviceId: pouch.isRemote ? pouch.deviceId : null,
      peerId: pouch.peerId,
      ownHostPouch: pouch.isRemote,
      usedBytes: _usedBytes,
      initialSpace: widget.initialSpace,
      // 带 initialSpace 进来的是一级「文件」入口或深链：锁在那个分区里，
      // 不再提供回到分区根列表的入口，免得从文件里又翻到玉简、指令集。
      lockToSpace: widget.initialSpace != null,
      hideInternalFiles: _hideInternalFiles,
      onHideInternalFilesChanged: (v) => setState(() => _hideInternalFiles = v),
      extraActions: [
        PopupMenuButton<StorageMoreAction>(
          tooltip: l10n.storage_moreSettings,
          icon: const Icon(Icons.more_horiz),
          position: PopupMenuPosition.under,
          onSelected: _handleMoreAction,
          itemBuilder: (ctx) => storageMoreMenuItems(
            ctx,
            l10n,
            hideInternalSelected: _hideInternalFiles,
          ),
        ),
      ],
      extraMenuItems: (ctx) => storageMoreMenuItems(
        ctx,
        l10n,
        hideInternalSelected: _hideInternalFiles,
      ),
      onExtraMenuSelected: (value) {
        if (value is StorageMoreAction) {
          _handleMoreAction(value);
        }
      },
    );
  }
}
