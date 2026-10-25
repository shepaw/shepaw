import 'package:flutter/material.dart';

import '../peer/services/peer_storage_service.dart';
import '../services/store_open_service.dart';
import '../storage/device_identity.dart';
import '../storage/group_workspace_service.dart';
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
/// 有 v3 袋子时直接进 `group:<gid>:shared`（共享记忆、交接、任务卷宗、共享
/// 文件都在这里）；`members/<agentId>/` 仍是 v2，从「旧数据（space 目录）」
/// 入口进。没有袋子（过渡期）时保持原来的 `workspaces/group_<gid>/` 视图。
Future<void> openGroupWorkspaceBag(
  BuildContext context, {
  required String groupId,
  String? title,
}) async {
  registerStorageDirectoryOpener();
  PouchScopeStore? scoped;
  try {
    scoped = await StoreService.instance.scopeStoreOrNull();
  } catch (_) {
    // 未配对之外的失败也退回 v2：至少要能看旧目录。
    scoped = null;
  }
  if (!context.mounted) return;
  if (scoped != null) {
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
    return;
  }
  await openGroupWorkspaceLegacyBag(context, groupId: groupId, title: title);
}

/// 群的 v2 目录视图（`workspaces/group_<gid>/`）：元数据与 `members/`。
Future<void> openGroupWorkspaceLegacyBag(
  BuildContext context, {
  required String groupId,
  String? title,
}) async {
  final ws = GroupWorkspaceService.instance;
  final meta = await ws.loadMeta(groupId);
  final deviceId = meta?.homeDevice ?? await DeviceIdentity.deviceId();
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
