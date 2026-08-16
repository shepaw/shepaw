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

    try {
      if (agent.isPeerAgent) {
        final peerId = agent.sourcePeerId;
        final remoteId = agent.remoteAgentId;
        if (peerId == null || remoteId == null) {
          if (mounted) {
            setState(() {
              _loadError = l10n.agentDetail_peerOffline;
              _loading = false;
            });
          }
          return;
        }
        if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
          if (mounted) {
            setState(() {
              _loadError = l10n.agentDetail_peerOffline;
              _loading = false;
            });
          }
          return;
        }
        final info = await PeerAgentClientService.instance.fetchSoulInfo(
          peerId: peerId,
          remoteAgentId: remoteId,
        );
        readOnly = !(info?.editable ?? false);
      }

      final soul = await AgentSoulService.instance.getSoul(agent);
      if (!mounted) return;
      setState(() {
        _initialSoul = soul;
        _readOnly = readOnly;
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

    return Scaffold(
      appBar: AppBar(
        title: Text(_readOnly ? l10n.agentDetail_systemPrompt : l10n.chat_soulTitle),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _loadError!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
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
