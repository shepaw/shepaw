import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/screens/peer_pairing_screen.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../storage/nexuspouch_discovery_service.dart';
import '../storage/store_service.dart';
import 'storage_shared.dart';

/// LAN discovery UI for Nexuspouch headless store masters.
class StorageNexuspouchScreen extends StatefulWidget {
  const StorageNexuspouchScreen({super.key});

  @override
  State<StorageNexuspouchScreen> createState() =>
      _StorageNexuspouchScreenState();
}

class _StorageNexuspouchScreenState extends State<StorageNexuspouchScreen> {
  final _discovery = NexuspouchDiscoveryService.instance;
  StreamSubscription<List<DiscoveredNexuspouch>>? _sub;
  List<DiscoveredNexuspouch> _peers = const [];
  bool _scanning = false;
  String? _busyFp;
  final _storage = PeerStorageService();

  @override
  void initState() {
    super.initState();
    _peers = _discovery.latest;
    _sub = _discovery.stream.listen((list) {
      if (mounted) setState(() => _peers = list);
    });
    unawaited(_scan());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      await _discovery.browse();
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _connect(DiscoveredNexuspouch node) async {
    final l10n = AppLocalizations.of(context);
    if (node.fingerprint.isEmpty) {
      storageToast(context, l10n.storage_nasMissingFingerprint);
      return;
    }
    setState(() => _busyFp = node.fingerprint);
    try {
      final peer = await _storage.getPeerByFingerprint(node.fingerprint);
      if (peer == null) {
        if (!mounted) return;
        final goPair = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.storage_nasNotPairedTitle),
            content: Text(l10n.storage_nasNotPairedBody(node.name)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.common_cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.storage_nasOpenPairing),
              ),
            ],
          ),
        );
        if (goPair == true && mounted) {
          await PeerPairingScreen.show(context,
              initialTabIndex: PeerPairingScreen.scanTabIndex);
        }
        return;
      }

      await _storage.updateLocalEndpoint(peer.id, node.endpoint);
      await PeerConnectionManager.instance.connectToPeer(peer);
      // Prefer this node as store master when connected.
      await StoreService.instance.setMasterDeviceId(node.fingerprint);
      if (mounted) {
        storageToast(context, l10n.storage_nasConnected(node.name));
      }
    } catch (e) {
      if (mounted) {
        storageToast(context, l10n.storage_nasConnectFailed('$e'));
      }
    } finally {
      if (mounted) setState(() => _busyFp = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.storage_entryNas),
        actions: [
          IconButton(
            icon: _scanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: l10n.common_refresh,
            onPressed: _scanning ? null : _scan,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            l10n.storage_nasHint,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 12),
          if (_peers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  _scanning
                      ? l10n.storage_nasScanning
                      : l10n.storage_nasEmpty,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            )
          else
            ..._peers.map((n) {
              final busy = _busyFp == n.fingerprint;
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: Text(n.name),
                  subtitle: Text(
                    [
                      if (n.fingerprint.isNotEmpty) n.shortFp,
                      n.endpoint,
                    ].join('\n'),
                  ),
                  isThreeLine: true,
                  trailing: busy
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton(
                          onPressed: () => _connect(n),
                          child: Text(l10n.storage_nasConnect),
                        ),
                ),
              );
            }),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => PeerPairingScreen.show(context),
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(l10n.storage_nasOpenPairing),
          ),
        ],
      ),
    );
  }
}
