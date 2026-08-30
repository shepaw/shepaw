import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/remote_agent.dart';
import '../peer/services/peer_connection_manager.dart';
import '../services/agent_resume_service.dart';

/// Full-screen 简历 editor for agent edit flow.
///
/// 支持手动编辑 + 输入提示词重新生成。三类 agent 的读写差异收在
/// [AgentResumeService]：
/// - 本机 / 外接 ACP：本机 `bio`；外接重新生成走 `agent.resume.rebuild(prompt)`。
/// - Peer：经 `agent_resume_*` 中继到宿主，宿主拒绝时只读。
///
/// [prefetchedResume] / [prefetchedEditable]：详情页已有结果时可跳过二次中继。
/// [prefetchFailed]：详情页已确认拉取失败时直接展示错误（仍可重试）。
class AgentResumeEditScreen extends StatefulWidget {
  final RemoteAgent agent;
  final String? prefetchedResume;
  final bool? prefetchedEditable;
  final bool prefetchFailed;

  const AgentResumeEditScreen({
    super.key,
    required this.agent,
    this.prefetchedResume,
    this.prefetchedEditable,
    this.prefetchFailed = false,
  });

  @override
  State<AgentResumeEditScreen> createState() => _AgentResumeEditScreenState();
}

class _AgentResumeEditScreenState extends State<AgentResumeEditScreen> {
  static const _uiLoadTimeout = Duration(seconds: 12);

  final _resumeController = TextEditingController();
  final _promptController = TextEditingController();

  bool _loading = true;
  bool _readOnly = false;
  bool _dirty = false;
  bool _regenerating = false;
  bool _saving = false;
  String? _loadError;
  Timer? _uiTimeout;
  /// 重试时忽略详情页预取，强制重新中继。
  bool _usePrefetch = true;

  @override
  void initState() {
    super.initState();
    _armUiTimeout();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _uiTimeout?.cancel();
    _resumeController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  /// 页面级硬超时：即使中继 Future 异常卡住，也必须结束转圈。
  void _armUiTimeout() {
    _uiTimeout?.cancel();
    _uiTimeout = Timer(_uiLoadTimeout, () {
      if (!mounted || !_loading) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        _loadError = l10n.resumeEdit_peerOffline;
        _loading = false;
      });
    });
  }

  void _finishLoad({required String resume, required bool readOnly}) {
    if (!mounted) return;
    _uiTimeout?.cancel();
    setState(() {
      _resumeController.text = resume;
      _readOnly = readOnly;
      _dirty = false;
      _loadError = null;
      _loading = false;
    });
  }

  void _failLoad(String error) {
    if (!mounted) return;
    _uiTimeout?.cancel();
    setState(() {
      _loadError = error;
      _loading = false;
    });
  }

  Future<void> _load() async {
    final l10n = AppLocalizations.of(context);
    final agent = widget.agent;

    setState(() => _loading = true);
    _armUiTimeout();

    // 详情页已有确定结果时，不再二次中继（editable=false 也不影响查看）。
    if (_usePrefetch && widget.prefetchFailed) {
      _failLoad(l10n.resumeEdit_peerOffline);
      return;
    }
    if (_usePrefetch && widget.prefetchedResume != null) {
      final editable = widget.prefetchedEditable ?? !agent.isPeerAgent;
      _finishLoad(
        resume: widget.prefetchedResume!,
        readOnly: agent.isPeerAgent ? !editable : false,
      );
      return;
    }

    if (agent.isPeerAgent &&
        agent.sourcePeerId != null &&
        !PeerConnectionManager.instance.connectedPeerIds
            .contains(agent.sourcePeerId)) {
      // 离线时用本地同步副本兜底（只读），让用户至少能查看。
      if ((agent.bio ?? '').trim().isEmpty) {
        _failLoad(l10n.agentDetail_peerOffline);
      } else {
        _finishLoad(resume: agent.bio ?? '', readOnly: true);
      }
      return;
    }

    try {
      final view = await AgentResumeService.instance.load(agent);
      if (view.error != null && view.resume.trim().isEmpty) {
        _failLoad(_loadErrorMessage(l10n, view.error));
        return;
      }
      _finishLoad(resume: view.resume, readOnly: !view.editable);
    } on TimeoutException {
      _failLoad(l10n.resumeEdit_peerOffline);
    } catch (e) {
      _failLoad(l10n.resumeEdit_saveFailed('$e'));
    }
  }

  String _loadErrorMessage(AppLocalizations l10n, String? code) {
    switch (code) {
      case 'offline':
        return l10n.resumeEdit_peerOffline;
      case 'denied':
        return l10n.resumeEdit_peerDenied;
      default:
        if (code != null && code.isNotEmpty) {
          return '${l10n.resumeEdit_peerOffline}\n($code)';
        }
        return l10n.resumeEdit_peerOffline;
    }
  }

  Future<void> _onRegenerate() async {
    final l10n = AppLocalizations.of(context);
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.resumeEdit_promptLabel)),
      );
      return;
    }
    final agent = widget.agent;
    // 外接 ACP 的 rebuild 在网关侧已直接落库，先确认再执行。
    final confirmed = !agent.isPeerAgent && !agent.isLocal
        ? await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text(l10n.agentDetail_regenerateResume),
              content: Text(l10n.agentDetail_regenerateResumeConfirm),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(l10n.common_cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(l10n.common_confirm),
                ),
              ],
            ),
          )
        : true;
    if (confirmed != true || !mounted) return;

    setState(() => _regenerating = true);
    try {
      final newText = await AgentResumeService.instance
          .regenerate(agent, prompt: prompt)
          .timeout(agent.isPeerAgent
              ? const Duration(seconds: 120)
              : const Duration(seconds: 90));
      if (!mounted) return;
      setState(() {
        _resumeController.text = newText;
        // local / peer：宿主 / 本机已落库，但编辑器内容仍以保存动作为准；
        // ACP：网关侧已落库，编辑器直接对齐新值。
        _dirty = agent.isLocal;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.resumeEdit_regenerateDone)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.agentDetail_regenerateResumeFailed('$e')),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _regenerating = false);
    }
  }

  Future<void> _onSave() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      final saved = await AgentResumeService.instance
          .save(widget.agent, _resumeController.text)
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() {
        _resumeController.text = saved;
        _dirty = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.resumeEdit_saved),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.of(context).pop(saved);
    } catch (e) {
      if (!mounted) return;
      final denied = '$e'.contains('resume_save_denied');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            denied ? l10n.resumeEdit_peerDenied : l10n.resumeEdit_saveFailed('$e'),
          ),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !_dirty) return;
        final discard = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            content: Text(l10n.resumeEdit_unsavedConfirm),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.common_cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(l10n.common_confirm),
              ),
            ],
          ),
        );
        if (discard == true && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.agentDetail_editResume),
          centerTitle: true,
          actions: [
            if (!_readOnly && _dirty && !_regenerating)
              TextButton(
                onPressed: _saving ? null : _onSave,
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.common_save),
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? _buildErrorPane(colorScheme, l10n)
                : _buildEditor(colorScheme, l10n),
      ),
    );
  }

  Widget _buildErrorPane(ColorScheme colorScheme, AppLocalizations l10n) {
    return Center(
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
                _usePrefetch = false;
                unawaited(_load());
              },
              child: Text(l10n.common_retry),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditor(ColorScheme colorScheme, AppLocalizations l10n) {
    final busy = _regenerating || _saving;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _resumeController,
            maxLines: 12,
            minLines: 6,
            readOnly: _readOnly || _regenerating,
            onChanged: (_) => setState(() => _dirty = true),
            decoration: InputDecoration(
              labelText: l10n.addAgent_agentBio,
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
              helperText: l10n.addAgent_agentBioHint,
            ),
          ),
          if (!_readOnly) ...[
            const SizedBox(height: 16),
            Text(
              l10n.resumeEdit_promptLabel,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _promptController,
              maxLines: 4,
              minLines: 2,
              enabled: !busy,
              decoration: InputDecoration(
                hintText: l10n.resumeEdit_promptHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: busy ? null : _onRegenerate,
                icon: _regenerating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome, size: 18),
                label: Text(
                  _regenerating
                      ? l10n.agentDetail_regeneratingResume
                      : l10n.agentDetail_regenerateResume,
                ),
              ),
            ),
          ],
          if (_readOnly) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.lock_outline,
                    size: 16, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.resumeEdit_peerDenied,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          if (!_readOnly)
            FilledButton(
              onPressed: (!_dirty || busy) ? null : _onSave,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.common_confirm),
            ),
        ],
      ),
    );
  }
}
