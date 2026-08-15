import 'package:flutter/material.dart';

import '../peer/services/peer_storage_service.dart';
import '../services/store_open_service.dart';
import '../storage/store_device_target.dart';
import 'storage_browser_screen.dart';

/// Register the pouch-browser jump used by chat `store://` folder links.
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
      ),
    ),
  );
}
