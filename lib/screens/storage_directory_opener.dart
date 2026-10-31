import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/store_open_service.dart';
import '../storage/device_identity.dart';
import '../storage/group_workspace_service.dart';
import '../storage/local_store.dart';
import '../storage/pouch_scope.dart';
import '../storage/pouch_scope_store.dart';
import '../storage/store_device_target.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import 'pouch_scope_browser_screen.dart';
import 'storage_browser_screen.dart';

/// Register the pouch-browser jump used by chat `pouch://` folder links.
///
/// Kept out of [StoreOpenService] to avoid an import cycle with this screen.
void registerStorageDirectoryOpener() {
  StoreOpenService.instance.openDirectory ??= (context, {required space, required deviceId, required path}) {
    return openStorageDirectoryInBrowser(
      context,
      space: space,
      deviceId: deviceId,
      path: path,
    );
  };
  StoreOpenService.instance.openScopeDirectory ??=
      (context, {required scope, required path}) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PouchScopeBrowserScreen(
          initialScope: scope,
          initialPath: path,
        ),
      ),
    );
  };
}

/// Open the group workspace bag.
///
/// 直接进 `group:<gid>:shared`（共享记忆、交接、任务卷宗、共享文件都在这里）。
/// `members/<agentId>/` 的新写入也走 v3（`group:<gid>:member:<aid>`），但它不
/// 出现在顶层 scope 列表里——成员私有区由 Agent 的 `pouch write` 落点与地址
/// 引用；旧目录仍可从「旧数据（space 目录）」入口看。
Future<void> openGroupWorkspaceBag(
  BuildContext context, {
  required String groupId,
  String? title,
}) async {
  registerStorageDirectoryOpener();
  final PouchScopeStore scoped;
  try {
    scoped = await StoreService.instance.scopeStore();
  } on StoreException catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(e.code == StoreError.notPaired
            ? AppLocalizations.of(context).storage_notPaired
            : '$e'),
      ),
    );
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => PouchScopeBrowserScreen(
        store: scoped,
        initialScope: PouchScope.groupShared(groupId),
        title: title,
        onOpenLegacy: () => openGroupWorkspaceLegacyBag(
          context,
          groupId: groupId,
          title: title,
        ),
      ),
    ),
  );
}

/// 群的 v2 目录视图（`workspaces/group_<gid>/`）：元数据与 `members/`。
Future<void> openGroupWorkspaceLegacyBag(
  BuildContext context, {
  required String groupId,
  String? title,
}) async {
  final ws = GroupWorkspaceService.instance;
  // 旧 workspaces/ 目录视图仍按本机设备展示；群元数据已不再决定 home device。
  final deviceId = await DeviceIdentity.deviceId();
  if (!context.mounted) return;
  await openStorageDirectoryInBrowser(
    context,
    space: StoreSpace.workspaces,
    deviceId: deviceId,
    path: ws.workspaceRoot(groupId),
    title: title,
  );
}

/// Push the storage browser at [space]/[path] on the device named in the URI.
///
/// [peerIdHint] is the pairing row for a peer agent when the URI device
/// fingerprint is missing from local peer records (still open via that
/// connection, using the peer's store fingerprint).
Future<void> openStorageDirectoryInBrowser(
  BuildContext context, {
  required String space,
  required String deviceId,
  required String path,
  String? peerIdHint,
  String? title,
}) async {
  var target = await StoreDeviceResolver.resolve(deviceId);
  if (!target.isLocal &&
      target.peerId == null &&
      peerIdHint != null &&
      peerIdHint.isNotEmpty) {
    final peer = await PeerStorageService().getPeerById(peerIdHint);
    if (peer != null) {
      target = StoreDeviceTarget(
        deviceId: peer.fingerprint,
        isLocal: false,
        peerId: peer.id,
        displayName: peer.deviceName.isNotEmpty ? peer.deviceName : null,
      );
    }
  }
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => StorageBrowserScreen(
        deviceId: target.deviceId,
        deviceName: target.displayName,
        peerId: target.peerId,
        readOnly: !target.isLocal,
        preferLocalCache: false,
        initialSpace: space,
        initialPath: path.isEmpty ? null : path,
        lockToInitialEntry: true,
        title: title,
      ),
    ),
  );
}
