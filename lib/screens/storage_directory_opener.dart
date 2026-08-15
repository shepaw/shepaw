import 'package:flutter/material.dart';

import '../services/store_open_service.dart';
import '../storage/store_device_target.dart';
import 'storage_browser_screen.dart';

/// Register the pouch-browser jump used by chat `store://` folder links.
///
/// Kept out of [StoreOpenService] to avoid an import cycle with this screen.
void registerStorageDirectoryOpener() {
  StoreOpenService.instance.openDirectory ??= openStorageDirectoryInBrowser;
}

/// Push the storage browser at [space]/[path] on the device named in the URI.
Future<void> openStorageDirectoryInBrowser(
  BuildContext context, {
  required String space,
  required String deviceId,
  required String path,
}) async {
  final target = await StoreDeviceResolver.resolve(deviceId);
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
