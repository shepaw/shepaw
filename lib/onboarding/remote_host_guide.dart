import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/pairing_payload.dart';
import '../peer/pouch_pair.dart';
import '../peer/screens/peer_scan_screen.dart';
import '../peer/services/peer_connection_manager.dart';
import '../services/logger_service.dart';
import 'host_entry.dart';
import 'host_setup_screen.dart';

/// 另一台电脑上的主机：两行命令，再粘贴配对链接。
class RemoteHostGuideScreen extends StatefulWidget {
  const RemoteHostGuideScreen({super.key});

  @override
  State<RemoteHostGuideScreen> createState() => _RemoteHostGuideScreenState();
}

class _RemoteHostGuideScreenState extends State<RemoteHostGuideScreen> {
  final _link = TextEditingController();
  bool _busy = false;
  String _error = '';

  bool get _phone => Platform.isAndroid || Platform.isIOS;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _connect(String raw) async {
    final l10n = AppLocalizations.of(context);
    final info = PeerPairingInfo.tryParse(raw.trim());
    if (info == null) {
      setState(() => _error = l10n.peerManual_invalidError);
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final peer = await PouchPairing.request(info);
      if (!mounted) return;
      final online =
          PeerConnectionManager.instance.connectedPeerIds.contains(peer.id);
      if (!online) {
        final enter = await _askOffline(l10n, peer.id);
        if (!mounted || enter == null) return;
        if (!enter) return;
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(
        '/pouch',
        arguments: PouchLoginArgs(hostPeerId: peer.id),
      );
    } catch (error) {
      LoggerService().error('remote host pair failed', tag: 'HostEntry', error: error);
      if (mounted) setState(() => _error = l10n.peer_pairingFailedRetry);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// true：仍然进入。false：留在这一页。
  Future<bool?> _askOffline(AppLocalizations l10n, String peerId) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.remoteHost_offline),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                final stored =
                    await PeerConnectionManager.instance.getAllPeers();
                final peer =
                    stored.where((item) => item.id == peerId).firstOrNull;
                if (peer == null) {
                  if (dialogContext.mounted) Navigator.pop(dialogContext, false);
                  return;
                }
                await PeerConnectionManager.instance.connectToPeer(
                  peer,
                  ignoreTieBreak: true,
                );
                if (dialogContext.mounted) Navigator.pop(dialogContext, true);
              } catch (_) {
                if (dialogContext.mounted) Navigator.pop(dialogContext, false);
              }
            },
            child: Text(l10n.widget_retry),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.remoteHost_enterAnyway),
          ),
        ],
      ),
    );
  }

  Future<void> _scan() async {
    final peer = await PeerScanScreen.show(context);
    if (peer == null || !mounted) return;
    Navigator.of(context).pushReplacementNamed(
      '/pouch',
      arguments: PouchLoginArgs(hostPeerId: peer.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final install = cliInstallCommand();
    const start = 'shepaw start && shepaw pair';
    return Scaffold(
      appBar: AppBar(title: Text(l10n.hostSetup_remote)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(l10n.remoteHost_intro),
          const SizedBox(height: 16),
          _CommandRow(text: install, onCopy: () => _copy(install)),
          const SizedBox(height: 8),
          _CommandRow(text: start, onCopy: () => _copy(start)),
          const SizedBox(height: 20),
          Text(l10n.remoteHost_pasteHint),
          const SizedBox(height: 8),
          TextField(
            controller: _link,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: 'shepaw://peer?...',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          if (_phone)
            FilledButton(
              onPressed: _busy ? null : _scan,
              child: Text(l10n.remoteHost_scan),
            ),
          if (_phone) const SizedBox(height: 8),
          _phone
              ? OutlinedButton(
                  onPressed: _busy ? null : () => _connect(_link.text),
                  child: Text(l10n.remoteHost_connect),
                )
              : FilledButton(
                  onPressed: _busy ? null : () => _connect(_link.text),
                  child: Text(l10n.remoteHost_connect),
                ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _CommandRow extends StatelessWidget {
  const _CommandRow({required this.text, required this.onCopy});

  final String text;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SelectableText(
            text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ),
        IconButton(
          onPressed: onCopy,
          icon: const Icon(Icons.copy, size: 18),
          tooltip: AppLocalizations.of(context).hostInstall_copyCommand,
        ),
      ],
    );
  }
}
