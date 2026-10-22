import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../add_agent_instance_logic.dart';
import '../services/peer_agent_client_service.dart';
import 'engine_setup_screen.dart';

/// 主机上的引擎列表、安装状态和运行时占用。
///
/// 引擎目录由主机在启动时预热并缓存，这里只做低频静默刷新；只有手动刷新
/// 才要求主机重扫 PATH。
class EngineManagementScreen extends StatefulWidget {
  final String peerId;

  /// 工作节点指纹。为空时读主机自己的引擎。
  final String? nodeId;

  /// 引擎在工作节点上时的节点名。
  final String? nodeName;

  const EngineManagementScreen({
    super.key,
    required this.peerId,
    this.nodeId,
    this.nodeName,
  });

  static Future<void> show(
    BuildContext context, {
    required String peerId,
    String? nodeId,
    String? nodeName,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => EngineManagementScreen(
          peerId: peerId,
          nodeId: nodeId,
          nodeName: nodeName,
        ),
      ),
    );
  }

  @override
  State<EngineManagementScreen> createState() => _EngineManagementScreenState();
}

class _EngineManagementScreenState extends State<EngineManagementScreen> {
  /// 页面打开时先空着，拿到第一份回包再画。
  PeerEngineStatusResult? _status;

  /// 第一份回包还没到。
  bool _loading = true;

  /// 手动刷新进行中，按钮转圈。
  bool _refreshing = false;

  /// 一次请求还没回来，定时器和手动刷新都不再叠加。
  bool _inFlight = false;

  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_inFlight) unawaited(_load(quiet: true));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false, bool refresh = false}) async {
    if (_inFlight) return;
    _inFlight = true;
    if (!quiet && mounted) setState(() => _refreshing = true);
    final result = await PeerAgentClientService.instance.engineStatus(
      peerId: widget.peerId,
      nodeId: widget.nodeId,
      refresh: refresh,
    );
    if (!mounted) return;
    setState(() {
      _inFlight = false;
      _refreshing = false;
      _loading = false;
      if (result.ok ||
          result.unsupported ||
          result.nodeOffline ||
          result.code == 'login_required') {
        _status = result;
        _error = null;
        return;
      }
      // 静默刷新失败时保留上一份数据，只在还没有数据时报错。
      _error = result.error;
      _status ??= result;
    });
  }

  Future<void> _openSetup(PeerEngineEntry engine) async {
    final again = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EngineSetupScreen(
          engine: engine,
          hostOnline: true,
          nodeName: widget.nodeName,
        ),
      ),
    );
    if (again == true && mounted) {
      await _load(refresh: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final status = _status;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.engineManagement_title),
        actions: [
          if (_refreshing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: l10n.engineManagement_refresh,
              onPressed: () => unawaited(_load(refresh: true)),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: _body(context, l10n, status),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    PeerEngineStatusResult? status,
  ) {
    if (_loading && status == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (status == null) {
      return _message(_error == 'offline'
          ? l10n.engineManagement_offline
          : l10n.engineManagement_loadFailed);
    }
    if (status.nodeOffline) {
      return _message(l10n.engineManagement_nodeOffline);
    }
    if (status.unsupported) {
      return _message(l10n.engineManagement_unsupported);
    }
    if (status.code == 'login_required') {
      return _message(l10n.engineManagement_loadFailed);
    }
    if (!status.ok) {
      return _message(status.error == 'offline'
          ? l10n.engineManagement_offline
          : l10n.engineManagement_loadFailed);
    }
    final engines = sortEnginesUnavailableLast(
      status.engines,
      (engine) => engine.available,
    );
    if (engines.isEmpty) {
      return _message(l10n.engineManagement_empty);
    }
    final summary = status.summary;
    final scannedAt = status.scannedAt;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            children: [
              Row(
                children: [
                  _statCard(
                    context,
                    l10n.engineManagement_availableEngines,
                    '${summary.availableEngines}/${summary.engines}',
                  ),
                  const SizedBox(width: 8),
                  _statCard(
                    context,
                    l10n.engineManagement_connections,
                    '${summary.connections}',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _statCard(
                    context,
                    l10n.engineManagement_activeConversations,
                    '${summary.activeConversations}',
                  ),
                  const SizedBox(width: 8),
                  _statCard(
                    context,
                    l10n.engineManagement_queuedConversations,
                    '${summary.queuedSessions}',
                  ),
                ],
              ),
            ],
          ),
        ),
        if (scannedAt > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              l10n.engineManagement_updatedAt(_clock(scannedAt)),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 8),
        for (final engine in engines)
          ListTile(
            leading: EngineAvatar(engine: engine, size: 36),
            title: Text(engine.name),
            subtitle: Text(
              l10n.engineManagement_perEngine(
                engine.instanceCount,
                engine.connections,
                engine.activeConversations,
                engine.queued,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                EngineStatusChip(
                  label: engine.available
                      ? l10n.addAgent_available
                      : l10n.addAgent_unavailable,
                  positive: engine.available,
                  color: engine.available
                      ? EngineStatusChip.availableColor(context)
                      : null,
                ),
                if (engine.instances.isNotEmpty)
                  const Icon(Icons.chevron_right),
              ],
            ),
            onTap: engine.instances.isNotEmpty
                ? () => unawaited(_openInstances(engine))
                : engine.available
                    ? null
                    : () => unawaited(_openSetup(engine)),
          ),
      ],
    );
  }

  /// 展开一个引擎的实例与会话，提供杀进程/结束对话。
  Future<void> _openInstances(PeerEngineEntry engine) async {
    final l10n = AppLocalizations.of(context);
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.85,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Row(
                children: [
                  EngineAvatar(engine: engine, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      engine.name,
                      style: Theme.of(sheetContext).textTheme.titleMedium,
                    ),
                  ),
                  EngineStatusChip(
                    label: engine.available
                        ? l10n.addAgent_available
                        : l10n.addAgent_unavailable,
                    positive: engine.available,
                    color: engine.available
                        ? EngineStatusChip.availableColor(sheetContext)
                        : null,
                  ),
                ],
              ),
              if (!engine.available) ...[
                const SizedBox(height: 8),
                Text(
                  engine.unavailableReason,
                  style: TextStyle(
                    color: Theme.of(sheetContext).colorScheme.error,
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    unawaited(_openSetup(engine));
                  },
                  icon: const Icon(Icons.settings_outlined),
                  label: Text(l10n.engineManagement_configure),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                l10n.engineManagement_instances,
                style: Theme.of(sheetContext).textTheme.titleSmall,
              ),
              for (final instance in engine.instances)
                _instanceCard(sheetContext, l10n, instance),
            ],
          ),
        ),
      ),
    );
    if (changed == true && mounted) {
      await _load(quiet: true);
    }
  }

  Widget _instanceCard(
    BuildContext sheetContext,
    AppLocalizations l10n,
    PeerEngineInstance instance,
  ) {
    final theme = Theme.of(sheetContext);
    final canKillProcess =
        instance.connections > 0 || instance.activeConversations > 0;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(instance.name, style: theme.textTheme.titleSmall),
                      if (instance.cwd.isNotEmpty)
                        Text(
                          instance.cwd,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                if (canKillProcess)
                  IconButton(
                    tooltip: l10n.engineManagement_killInstance,
                    icon: const Icon(Icons.power_settings_new),
                    onPressed: () => unawaited(_killInstance(
                      sheetContext,
                      l10n,
                      instance,
                    )),
                  ),
              ],
            ),
            Text(
              l10n.engineManagement_instanceUsage(
                instance.connections,
                instance.activeConversations,
                instance.queued,
              ),
              style: theme.textTheme.bodySmall,
            ),
            const Divider(height: 16),
            Text(l10n.engineManagement_sessions, style: theme.textTheme.labelLarge),
            if (instance.sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  l10n.engineManagement_noSessions,
                  style: theme.textTheme.bodySmall,
                ),
              )
            else
              for (final session in instance.sessions)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(_shortSession(session.sessionKey)),
                  subtitle: Text(_sessionStatus(l10n, session)),
                  trailing: (session.running || session.idle || session.queued > 0)
                      ? TextButton(
                          onPressed: () => unawaited(_killSession(
                            sheetContext,
                            l10n,
                            instance,
                            session,
                          )),
                          child: Text(l10n.engineManagement_killSession),
                        )
                      : null,
                ),
            if (instance.sessions.isEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: canKillProcess
                      ? () => unawaited(_killInstance(
                            sheetContext,
                            l10n,
                            instance,
                          ))
                      : null,
                  child: Text(l10n.engineManagement_killInstance),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _killInstance(
    BuildContext sheetContext,
    AppLocalizations l10n,
    PeerEngineInstance instance,
  ) async {
    final confirmed = await _confirm(
      l10n.engineManagement_killInstance,
      l10n.engineManagement_killInstanceConfirm(instance.name),
      l10n.engineManagement_killInstance,
    );
    if (confirmed != true || !mounted) return;
    final result = await PeerAgentClientService.instance.engineControl(
      peerId: widget.peerId,
      nodeId: widget.nodeId,
      op: 'kill_instance',
      instanceId: instance.id,
    );
    if (!mounted) return;
    if (!result.ok) {
      _showError(l10n, result);
      return;
    }
    if (sheetContext.mounted) {
      Navigator.pop(sheetContext, true);
    } else {
      await _load(quiet: true);
    }
  }

  Future<void> _killSession(
    BuildContext sheetContext,
    AppLocalizations l10n,
    PeerEngineInstance instance,
    PeerEngineSession session,
  ) async {
    final confirmed = await _confirm(
      l10n.engineManagement_killSession,
      l10n.engineManagement_killSessionConfirm,
      l10n.engineManagement_killSession,
    );
    if (confirmed != true || !mounted) return;
    final result = await PeerAgentClientService.instance.engineControl(
      peerId: widget.peerId,
      nodeId: widget.nodeId,
      op: 'kill_session',
      instanceId: instance.id,
      sessionKey: session.sessionKey,
    );
    if (!mounted) return;
    if (!result.ok) {
      _showError(l10n, result);
      return;
    }
    if (sheetContext.mounted) {
      Navigator.pop(sheetContext, true);
    } else {
      await _load(quiet: true);
    }
  }

  Future<bool?> _confirm(String title, String message, String action) {
    final l10n = AppLocalizations.of(context);
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  void _showError(AppLocalizations l10n, PeerEngineControlResult result) {
    final message = result.unsupported
        ? l10n.engineManagement_unsupported
        : l10n.engineManagement_killFailed(result.error ?? '');
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _sessionStatus(AppLocalizations l10n, PeerEngineSession session) {
    final parts = <String>[
      if (session.running)
        l10n.engineManagement_running
      else if (session.idle)
        l10n.engineManagement_idle,
      if (session.queued > 0) '${session.queued} ${l10n.engineManagement_queued}',
    ];
    return parts.join(' · ');
  }

  String _shortSession(String key) {
    if (key.length <= 18) return key;
    return '${key.substring(0, 10)}…${key.substring(key.length - 6)}';
  }

  Widget _statCard(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _message(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(text, textAlign: TextAlign.center),
      ),
    );
  }

  /// 主机时间戳只精确到秒，页面里也只显示到秒。
  String _clock(int milliseconds) {
    final at = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }
}
