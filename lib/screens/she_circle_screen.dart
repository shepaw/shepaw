import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/paired_peer.dart';
import '../peer/services/peer_agent_client_service.dart' show resolvePeerAgentRowId;
import '../peer/services/peer_storage_service.dart';
import '../service_locator.dart';
import '../services/local_database_service.dart';
import '../services/remote_agent_service.dart';
import '../services/she_service.dart';
import '../she_network/digest_service.dart';
import '../she_network/exchange_settings.dart';
import '../she_network/external_memory_store.dart';
import '../she_network/memory_exchange_service.dart';
import '../she_network/presence_profile.dart' show PresenceAgentEntry;
import '../she_network/presence_service.dart';
import '../she_network/presence_settings.dart';
import '../she_network/she_network_protocol.dart';
import '../storage/store_protocol.dart' show TrustLevel;
import 'remote_agent_detail_screen.dart';
import 'storage_shared.dart';

/// 她的朋友圈子页：与 owner 级设备交换蒸馏摘要。
/// 入口在本机 She 详情页（已从储物袋迁出）。
class SheCircleScreen extends StatefulWidget {
  const SheCircleScreen({super.key});

  @override
  State<SheCircleScreen> createState() => _SheCircleScreenState();
}

class _SheCircleScreenState extends State<SheCircleScreen> {
  bool _busy = false;

  ExchangeSettings _exchange =
      ExchangeSettings(enabled: false, kinds: {...DigestKind.all});
  PresenceSettings _presenceSettings = PresenceSettings(shareRoster: false);
  List<PairedPeer> _ownerPeers = [];
  Map<String, int> _extCounts = {};
  String _localSheName = SheService.sheName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _exchange = await ExchangeSettings.load();
    _presenceSettings = await PresenceSettings.load();
    final peers = await PeerStorageService().loadAllPeers();
    _ownerPeers =
        peers.where((p) => p.trustLevel == TrustLevel.owner).toList();
    _extCounts = await ExternalMemoryStore.instance.countsByDevice();
    _localSheName = await DigestService.instance.localSheName();
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------ 操作

  Future<void> _exchangeNow() async {
    setState(() => _busy = true);
    try {
      final ok = await MemoryExchangeService.instance.offerToAllOwners();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      storageToast(
          context, ok ? l10n.storage_exchangeDone : l10n.storage_exchangeSkipped);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renameLocalShe() async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController(
      text: SheService.resolveDisplayName(_localSheName, l10n.she_name),
    );
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.storage_renameShe),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.storage_renameSheHint,
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(hintText: l10n.she_name),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(MaterialLocalizations.of(ctx).okButtonLabel)),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final normalized = SheService.normalizeStoredName(name, l10n.she_name);
    try {
      final agentService = getIt<RemoteAgentService>();
      final agent = await agentService.getAgentById(SheService.sheId);
      if (agent != null) {
        await agentService.updateAgent(agent.copyWith(name: normalized));
      }
      await PresenceService.instance
          .broadcastNow(localizedSheName: l10n.she_name);
      setState(() => _localSheName = normalized);
      storageToast(context, l10n.storage_sheNameSaved);
    } catch (e) {
      storageToast(context, '$e');
    }
  }

  Future<void> _pickDelegateAgent(
    AppLocalizations l10n,
    PairedPeer peer,
    ShePresence presence,
  ) async {
    final picked = await showModalBottomSheet<PresenceAgentEntry>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(l10n.storage_pickDelegateAgent)),
            for (final a in presence.agents)
              ListTile(
                title: Text(a.name),
                subtitle: Text(a.category),
                onTap: () => Navigator.pop(ctx, a),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    // Hub UUID when safe; reserved ids (惜宝) and legacy rows resolve via
    // resolvePeerAgentRowId / decidePeerAgentRowId.
    final localId = await resolvePeerAgentRowId(
      getIt<LocalDatabaseService>(),
      peer.id,
      picked.id,
    );
    try {
      final agent = await getIt<RemoteAgentService>().getAgentById(localId);
      if (agent == null || !mounted) {
        storageToast(context, l10n.storage_presenceOffline);
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RemoteAgentDetailScreen(agent: agent),
        ),
      );
    } catch (e) {
      storageToast(context, '$e');
    }
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final presence = PresenceService.instance.known;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.storage_sheCircleSection)),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${l10n.storage_sheCircleHint}\n${SheService.resolveDisplayName(_localSheName, l10n.she_name)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          TextButton(
                            onPressed: _busy ? null : _renameLocalShe,
                            child: Text(l10n.storage_renameShe),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.storage_exchangeEnabled),
                        value: _exchange.enabled,
                        onChanged: _busy
                            ? null
                            : (v) async {
                                final next = _exchange.copyWith(enabled: v);
                                await next.save();
                                setState(() => _exchange = next);
                              },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.storage_sharePresenceRoster),
                        subtitle: Text(
                            l10n.storage_sharePresenceRosterHint,
                            style:
                                Theme.of(context).textTheme.bodySmall),
                        value: _presenceSettings.shareRoster,
                        onChanged: _busy
                            ? null
                            : (v) async {
                                final next = _presenceSettings
                                    .copyWith(shareRoster: v);
                                await next.save();
                                setState(
                                    () => _presenceSettings = next);
                                await PresenceService.instance
                                    .broadcastNow(
                                        localizedSheName:
                                            l10n.she_name);
                                if (mounted) setState(() {});
                              },
                      ),
                      Text(l10n.storage_exchangeKinds,
                          style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final kind in DigestKind.all)
                            FilterChip(
                              label: Text(_kindLabel(l10n, kind)),
                              selected: _exchange.kinds.contains(kind),
                              onSelected: _busy
                                  ? null
                                  : (sel) async {
                                      final kinds =
                                          Set<String>.of(_exchange.kinds);
                                      if (sel) {
                                        kinds.add(kind);
                                      } else {
                                        kinds.remove(kind);
                                      }
                                      if (kinds.isEmpty) return;
                                      final next = _exchange
                                          .copyWith(kinds: kinds);
                                      await next.save();
                                      setState(() => _exchange = next);
                                    },
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.tonal(
                          onPressed:
                              _busy || !_exchange.enabled ? null : _exchangeNow,
                          child: Text(l10n.storage_exchangeNow),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(l10n.storage_sheCircleSection,
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Card(
                child: _ownerPeers.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(l10n.storage_noOwnerPeers,
                            style: Theme.of(context).textTheme.bodySmall),
                      )
                    : Column(
                        children: [
                          for (final peer in _ownerPeers)
                            _buildPeerTile(l10n, presence, peer),
                        ],
                      ),
              ),
            ],
          ),
          if (_busy) const StorageBusyOverlay(),
        ],
      ),
    );
  }

  Widget _buildPeerTile(AppLocalizations l10n,
      Map<String, ShePresence> presence, PairedPeer peer) {
    final p = presence[peer.fingerprint];
    final count = _extCounts[peer.fingerprint] ?? 0;
    final title =
        p?.sheName.isNotEmpty == true ? p!.sheName : peer.deviceName;
    return ListTile(
      title: Text(title),
      subtitle: Text(
        '${l10n.storage_peerTrust(peer.trustLevel)} · '
        '${l10n.storage_externalMemories(count)}'
        '${_presenceSubtitle(l10n, p)}',
      ),
      dense: true,
      onTap: p != null && p.agents.isNotEmpty
          ? () => _pickDelegateAgent(l10n, peer, p)
          : null,
    );
  }

  String _presenceSubtitle(AppLocalizations l10n, ShePresence? p) {
    if (p == null || !p.online) {
      return ' · ${l10n.storage_presenceOffline}';
    }
    final cats = <String>[
      ...p.agentCategories,
      ...p.toolCategories,
    ];
    final catPart = cats.isEmpty ? '' : ' · ${cats.join('/')}';
    final rosterPart = p.agents.isEmpty
        ? ''
        : ' · ${l10n.storage_presenceAgents(p.agents.map((a) => a.name).join(', '))}';
    return ' · ${p.agentCount}$catPart$rosterPart';
  }

  String _kindLabel(AppLocalizations l10n, String kind) {
    switch (kind) {
      case DigestKind.preference:
        return l10n.storage_kindPreference;
      case DigestKind.ongoing:
        return l10n.storage_kindOngoing;
      case DigestKind.fact:
        return l10n.storage_kindFact;
      default:
        return kind;
    }
  }
}
