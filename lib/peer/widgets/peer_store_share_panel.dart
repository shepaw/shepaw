import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../storage/store_service.dart';
import '../models/peer_store_share.dart';
import '../services/peer_storage_service.dart';
import 'peer_store_share_selector.dart';

/// 配对后「我分享给对方」的储物袋分享面板。
class PeerStoreSharePanel extends StatefulWidget {
  final String peerId;

  const PeerStoreSharePanel({super.key, required this.peerId});

  @override
  State<PeerStoreSharePanel> createState() => _PeerStoreSharePanelState();
}

class _PeerStoreSharePanelState extends State<PeerStoreSharePanel> {
  bool _loading = true;
  Map<String, PeerStoreShareSpaceState> _states =
      defaultStoreShareStates('friend');
  int _selectorKey = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries =
          await PeerStorageService().getSharedStoreEntries(widget.peerId);
      if (!mounted) return;
      setState(() {
        _states = entries.isEmpty
            ? defaultStoreShareStates('friend')
            : storeShareStatesFromEntries(entries);
        _loading = false;
        _selectorKey++;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onChanged(List<PeerStoreShareEntry> entries) async {
    await StoreService.instance.setOutboundStoreShares(widget.peerId, entries);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text(
          l10n.peerStoreShare_panelTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          l10n.peerStoreShare_panelHint,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 12),
        PeerStoreShareSelector(
          key: ValueKey(_selectorKey),
          initialStates: _states,
          onChanged: _onChanged,
        ),
      ],
    );
  }
}
