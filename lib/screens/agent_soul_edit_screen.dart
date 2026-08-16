import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/remote_agent.dart';
import '../peer/services/peer_agent_client_service.dart';
import '../peer/services/peer_connection_manager.dart';
import '../services/agent_soul_service.dart';
import '../widgets/chat/soul_panel.dart';

/// Full-screen Soul editor for agent edit flow.
class AgentSoulEditScreen extends StatefulWidget {
  final RemoteAgent agent;

  const AgentSoulEditScreen({super.key, required this.agent});

  @override
  State<AgentSoulEditScreen> createState() => _AgentSoulEditScreenState();
}

class _AgentSoulEditScreenState extends State<AgentSoulEditScreen> {
  bool _loading = true;
  bool _startedLoad = false;
  String _initialSoul = '';
  bool _readOnly = false;
  String? _loadError;
  bool _soulMissing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // AppLocalizations.of(context) needs InheritedWidget; cannot run in initState.
    if (_startedLoad) return;
    _startedLoad = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    final l10n = AppLocalizations.of(context);
    final agent = widget.agent;
    var readOnly = false;
    var soul = '';
    var missing = false;

    try {
      if (agent.isPeerAgent) {
        final peerId = agent.sourcePeerId;
        final remoteId = agent.remoteAgentId;
        if (peerId == null ||
            remoteId == null ||
            !PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
          if (mounted) {
            setState(() {
              _loadError = l10n.agentDetail_peerOffline;
              _loading = false;
            });
          }
          return;
        }
        // 单次拉取：正文 + 可编辑标记，避免再调 getSoul 触发第二次 peer req。
        final info = await PeerAgentClientService.instance.fetchSoulInfo(
          peerId: peerId,
          remoteAgentId: remoteId,
        );
        if (info == null) {
          if (mounted) {
            setState(() {
              _loadError = l10n.chat_soulFetchFailed;
              _loading = false;
            });
          }
          return;
        }
        soul = info.soul;
        readOnly = !info.editable;
        missing = soul.trim().isEmpty;
      } else {
        soul = await AgentSoulService.instance.getSoul(agent);
        missing = soul.trim().isEmpty;
      }

      if (!mounted) return;
      setState(() {
        _initialSoul = soul;
        _readOnly = readOnly;
        _soulMissing = missing;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = l10n.agentDetail_saveFailed('$e');
        _loading = false;
      });
    }
  }

  Future<bool> _save(String soul) async {
    final l10n = AppLocalizations.of(context);
    final agent = widget.agent;
    final ok = await AgentSoulService.instance.updateSoul(agent, soul);
    if (!mounted) return false;
    if (!ok && agent.isPeerAgent) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.chat_soulDenied)),
      );
      return false;
    }
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.agentDetail_saveFailed('')),
          backgroundColor: Colors.red,
        ),
      );
      return false;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.chat_soulSaved),
        backgroundColor: Colors.green,
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _readOnly ? l10n.agentDetail_systemPrompt : l10n.chat_soulTitle,
        ),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.cloud_off_outlined,
                          size: 48,
                          color: colorScheme.error,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _loadError!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colorScheme.error),
                        ),
                        const SizedBox(height: 24),
                        FilledButton.tonal(
                          onPressed: () {
                            setState(() {
                              _loading = true;
                              _loadError = null;
                            });
                            unawaited(_load());
                          },
                          child: Text(l10n.common_retry),
                        ),
                      ],
                    ),
                  ),
                )
              : _soulMissing && _readOnly
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.psychology_outlined,
                              size: 48,
                              color: colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              l10n.chat_soulEmpty,
                              style: Theme.of(context).textTheme.titleMedium,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              l10n.chat_soulEmptyDesc,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 24),
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: Text(l10n.common_close),
                            ),
                          ],
                        ),
                      ),
                    )
                  : SoulPanel(
                      initialSoul: _initialSoul,
                      readOnly: _readOnly,
                      onSave: _save,
                    ),
    );
  }
}
