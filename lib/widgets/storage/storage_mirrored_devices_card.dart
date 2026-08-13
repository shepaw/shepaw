import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/paired_peer.dart';
import '../../screens/storage_browser_screen.dart';
import '../../screens/storage_shared.dart';
import '../../storage/store_protocol.dart';

class MirroredDeviceRow {
  const MirroredDeviceRow({
    required this.deviceId,
    required this.name,
    required this.bytes,
    this.peerId,
  });

  final String deviceId;
  final String name;
  final int bytes;
  final String? peerId;
}

/// master 本机：列出并管理同步过来的他端储物空间。
class StorageMirroredDevicesCard extends StatelessWidget {
  const StorageMirroredDevicesCard({
    super.key,
    required this.devices,
    required this.busy,
    required this.onPurge,
  });

  final List<MirroredDeviceRow> devices;
  final bool busy;
  final Future<void> Function(MirroredDeviceRow device) onPurge;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.storage_mirroredDevices,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              devices.isEmpty
                  ? l10n.storage_mirroredDevicesHint
                  : l10n.storage_mirroredDevicesNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            if (devices.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 4),
                child: Text(
                  l10n.storage_mirroredEmpty,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              )
            else
              for (final d in devices) _deviceTile(context, l10n, d),
          ],
        ),
      ),
    );
  }

  Widget _deviceTile(
    BuildContext context,
    AppLocalizations l10n,
    MirroredDeviceRow device,
  ) {
    final shortId = device.deviceId.length > 8
        ? '${device.deviceId.substring(0, 8)}…'
        : device.deviceId;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.devices_outlined),
      title: Text(device.name),
      subtitle: Text('$shortId · ${fmtStorageBytes(device.bytes)}'),
      trailing: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'browse':
                    _browse(context, device);
                  case 'purge':
                    onPurge(device);
                }
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(
                  value: 'browse',
                  child: Text(l10n.storage_mirroredBrowse),
                ),
                PopupMenuItem(
                  value: 'purge',
                  child: Text(l10n.storage_purgeDevice),
                ),
              ],
            ),
      onTap: () => _browse(context, device),
    );
  }

  void _browse(BuildContext context, MirroredDeviceRow device) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StorageBrowserScreen(
          deviceId: device.deviceId,
          deviceName: device.name,
          peerId: device.peerId,
          preferLocalCache: true,
          manageLocalMirror: true,
          readOnly: false,
          usedBytes: device.bytes,
        ),
      ),
    );
  }
}

Future<List<MirroredDeviceRow>> loadMirroredDevices({
  required String selfId,
  required List<PairedPeer> peers,
  required Map<String, dynamic> stats,
}) async {
  final devices = (stats['devices'] as Map?)?.cast<String, dynamic>() ?? {};
  final rows = <MirroredDeviceRow>[];
  for (final e in devices.entries) {
    if (e.key == selfId) continue;
    if (!isValidDeviceId(e.key)) continue;
    final perSpace = (e.value as Map?)?.cast<String, dynamic>() ?? {};
    var total = 0;
    for (final v in perSpace.values) {
      if (v is int) total += v;
      if (v is num) total += v.toInt();
    }
    final peer = peers.where((p) => p.fingerprint == e.key).firstOrNull;
    rows.add(MirroredDeviceRow(
      deviceId: e.key,
      name: peer?.deviceName.isNotEmpty == true ? peer!.deviceName : e.key,
      bytes: total,
      peerId: peer?.id,
    ));
  }
  rows.sort((a, b) => b.bytes.compareTo(a.bytes));
  return rows;
}
