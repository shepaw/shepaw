import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/remote_agent.dart';
import '../peer/services/peer_agent_client_service.dart';
import '../peer/services/peer_connection_manager.dart';
import '../services/agent_soul_service.dart';
import '../widgets/chat/soul_panel.dart';

/// Full-screen Soul editor for agent edit flow.
///
/// [prefetchedSoul] / [prefetchedEditable]：详情页已拉到的结果，可跳过二次中继。
/// [prefetchFailed]：详情页已确认拉取失败时直接展示错误（仍可重试）。
class AgentSoulEditScreen extends StatefulWidget {
  final RemoteAgent agent;
  final String? prefetchedSoul;
  final bool? prefetchedEditable;
  final bool prefetchFailed;

  const AgentSoulEditScreen({
    super.key,
    required this.agent,
    this.prefetchedSoul,
    this.prefetchedEditable,
    this.prefetchFailed = false,
  });

  @override
  State<AgentSoulEditScreen> createState() => _AgentSoulEditScreenState();
}

class _AgentSoulEditScreenState extends State<AgentSoulEditScreen> {
  static const _uiLoadTimeout = Duration(seconds: 12);

  bool _loading = true;
  String _initialSoul = '';
  bool _readOnly = false;
  String? _loadError;
  bool _soulMissing = false;
  Timer? _uiTimeout;
  /// 重试时忽略详情页预取，强制重新中继。
  bool _usePrefetch = true;
  /// 已经把灵魂画出来（缓存或预取）。之后的失败不能再盖成错误页。
  bool _showingSoul = false;

  @override
  void initState() {
    super.initState();
    // 页面级硬超时：即使中继 Future 异常卡住，也必须结束转圈。
    _uiTimeout = Timer(_uiLoadTimeout, () {
      if (!mounted || !_loading) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        _loadError = l10n.chat_soulFetchFailed;
        _loading = false;
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _uiTimeout?.cancel();
    super.dispose();
  }

  void _finishLoad({
    required String soul,
    required bool readOnly,
    String? error,
  }) {
    if (!mounted) return;
    _uiTimeout?.cancel();
    setState(() {
      if (error != null) {
        _loadError = error;
        _loading = false;
        return;
      }
      _initialSoul = soul;
      _readOnly = readOnly;
      _soulMissing = soul.trim().isEmpty;
      _loadError = null;
      _loading = false;
    });
  }

  void _presentSoul({
    required String soul,
    required bool readOnly,
    bool background = false,
  }) {
    _showingSoul = true;
    if (background && !_loading && _loadError == null) {
      if (!mounted) return;
      _uiTimeout?.cancel();
      setState(() {
        _initialSoul = soul;
        _readOnly = readOnly;
        _soulMissing = soul.trim().isEmpty;
      });
      return;
    }
    _finishLoad(soul: soul, readOnly: readOnly);
  }

  Future<void> _load() async {
    final l10n = AppLocalizations.of(context);
    final agent = widget.agent;

    try {
      if (!agent.isPeerAgent) {
        if (_usePrefetch && widget.prefetchFailed) {
          _finishLoad(soul: '', readOnly: true, error: l10n.chat_soulFetchFailed);
          return;
        }
        if (_usePrefetch && widget.prefetchedSoul != null) {
          _finishLoad(soul: widget.prefetchedSoul!, readOnly: false);
          return;
        }
        final soul = await AgentSoulService.instance
            .getSoul(agent)
            .timeout(_uiLoadTimeout);
        _finishLoad(soul: soul, readOnly: false);
        return;
      }

      final peerId = agent.sourcePeerId;
      final remoteId = agent.remoteAgentId;
      final connected = peerId != null &&
          remoteId != null &&
          PeerConnectionManager.instance.connectedPeerIds.contains(peerId);

      PeerSoulInfo? cached;
      if (_usePrefetch && !widget.prefetchFailed && widget.prefetchedSoul != null) {
        cached = PeerSoulInfo.ok(
          soul: widget.prefetchedSoul!,
          editable: widget.prefetchedEditable ?? false,
        );
      } else {
        cached = await PeerAgentClientService.instance.cachedSoul(agent.id);
      }

      if (cached != null && cached.isOk) {
        _presentSoul(
          soul: cached.soul,
          readOnly: !connected || !cached.editable,
        );
      }

      if (!connected) {
        if (cached == null) {
          _finishLoad(
            soul: '',
            readOnly: true,
            error: l10n.agentDetail_peerOffline,
          );
        }
        return;
      }

      final info = await PeerAgentClientService.instance
          .fetchSoulInfo(peerId: peerId, remoteAgentId: remoteId)
          .timeout(_uiLoadTimeout);
      if (info == null || !info.isOk) {
        if (!_showingSoul) {
          _finishLoad(
            soul: '',
            readOnly: true,
            error: info == null
                ? l10n.chat_soulFetchFailed
                : _soulErrorMessage(l10n, info.error),
          );
        }
        return;
      }
      _presentSoul(
        soul: info.soul,
        readOnly: !info.editable,
        background: cached != null,
      );
    } on TimeoutException {
      if (!_showingSoul) {
        _finishLoad(
          soul: '',
          readOnly: true,
          error: l10n.chat_soulFetchFailed,
        );
      }
    } catch (e) {
      if (!_showingSoul) {
        _finishLoad(
          soul: '',
          readOnly: true,
          error: l10n.agentDetail_saveFailed('$e'),
        );
      }
    }
  }

  String _soulErrorMessage(AppLocalizations l10n, String? code) {
    switch (code) {
      case 'not_available':
        return l10n.chat_soulFetchFailed;
      case 'timeout':
        return l10n.chat_soulFetchFailed;
      case 'missing_agent_id':
        return l10n.chat_soulFetchFailed;
      default:
        if (code != null && code.isNotEmpty) {
          return '${l10n.chat_soulFetchFailed}\n($code)';
        }
        return l10n.chat_soulFetchFailed;
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
                              _usePrefetch = false;
                            });
                            _uiTimeout?.cancel();
                            _uiTimeout = Timer(_uiLoadTimeout, () {
                              if (!mounted || !_loading) return;
                              setState(() {
                                _loadError =
                                    AppLocalizations.of(context).chat_soulFetchFailed;
                                _loading = false;
                              });
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
