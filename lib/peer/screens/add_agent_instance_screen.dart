import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../models/remote_agent.dart';
import '../../screens/chat_screen.dart';
import '../../service_locator.dart';
import '../../services/contacts_directory.dart';
import '../../services/local_database_service.dart';
import '../../storage/pouch_session.dart';
import '../../widgets/host_directory_picker.dart';
import '../add_agent_instance_logic.dart';
import 'engine_setup_screen.dart';
import '../services/peer_agent_client_service.dart';
import '../services/peer_connection_manager.dart';
import '../services/peer_storage_service.dart';

/// 没提交就关掉时留下的表单。换节点或提交成功后清掉。
class AddAgentInstanceDraft {
  AddAgentInstanceDraft({
    required this.targetKey,
    required this.engineId,
    required this.sessionMode,
    required this.name,
    required this.nameTouched,
    required this.cwd,
    required this.extras,
  });

  /// [AgentTarget.key]：主机是连接 id，工作节点是 `<连接 id>@<节点指纹>`。
  final String? targetKey;
  final String? engineId;
  final String? sessionMode;
  final String name;
  final bool nameTouched;
  final String cwd;
  final List<String> extras;
}

class AddAgentInstanceScreen extends StatefulWidget {
  const AddAgentInstanceScreen({
    super.key,
    this.presetPeerId,
    this.presetNodeId,
    this.embedded = false,
    this.onCreated,
    this.onClose,
  });

  final String? presetPeerId;

  /// 从通讯录某个工作节点进来时预选这个节点。
  final String? presetNodeId;
  final bool embedded;

  /// 桌面右栏：交给外层去打开聊天。手机端为 null 时，自己 push ChatScreen。
  final void Function(RemoteAgent agent)? onCreated;
  final VoidCallback? onClose;

  static AddAgentInstanceDraft? draft;

  @override
  State<AddAgentInstanceScreen> createState() => _AddAgentInstanceScreenState();
}

class _AddAgentInstanceScreenState extends State<AddAgentInstanceScreen> {
  final _nameController = TextEditingController();
  final _extraControllers = <TextEditingController>[];

  List<AgentTarget> _targets = const [];
  AgentTarget? _target;
  List<PeerEngineEntry> _engines = const [];
  String? _engineId;
  String? _sessionMode;
  String _cwd = '';
  List<String> _history = const [];
  List<String> _instanceCwds = const [];
  String _error = '';
  bool _loading = true;
  bool _submitting = false;
  bool _submitted = false;
  bool _nameTouched = false;
  bool _applyingName = false;
  StreamSubscription<dynamic>? _connectionSub;
  StreamSubscription<ContactsView>? _directorySub;

  String? get _peerId => _target?.peerId;
  String? get _nodeId => _target?.nodeId;

  /// 请求要经过的连接在线；工作节点还要节点本身在线。
  bool get _hostOnline {
    final target = _target;
    if (target == null) return false;
    return _isOnline(target);
  }

  bool _isOnline(AgentTarget target) {
    final connected = PeerConnectionManager.instance.connectedPeerIds;
    if (!connected.contains(target.peerId)) return false;
    return target.nodeId == null || target.online;
  }

  @override
  void initState() {
    super.initState();
    _connectionSub = PeerConnectionManager.instance.events.listen((_) {
      if (mounted) setState(() {});
    });
    final draft = AddAgentInstanceScreen.draft;
    final preset = widget.presetPeerId != null || widget.presetNodeId != null;
    if (draft != null && preset && !_draftMatchesPreset(draft.targetKey)) {
      AddAgentInstanceScreen.draft = null;
    }
    _nameController.addListener(() {
      if (_applyingName) return;
      _nameTouched = true;
    });
    unawaited(_loadDevices());
  }

  @override
  void dispose() {
    _connectionSub?.cancel();
    _directorySub?.cancel();
    if (!_submitted) {
      AddAgentInstanceScreen.draft = AddAgentInstanceDraft(
        targetKey: _target?.key,
        engineId: _engineId,
        sessionMode: _sessionMode,
        name: _nameController.text,
        nameTouched: _nameTouched,
        cwd: _cwd,
        extras: [for (final field in _extraControllers) field.text],
      );
    }
    _nameController.dispose();
    for (final field in _extraControllers) {
      field.dispose();
    }
    super.dispose();
  }

  bool _draftMatchesPreset(String? key) {
    if (key == null) return false;
    final node = widget.presetNodeId;
    if (node != null) return key.endsWith('@$node');
    return key == widget.presetPeerId;
  }

  Future<void> _loadDevices() async {
    final session = await PouchSessionStore.readActive();
    final peers = await PeerStorageService().loadAllPeers();
    final byId = {for (final peer in peers) peer.id: peer};
    final hostId = widget.presetPeerId ?? session?.hostPeerId;
    final connected = PeerConnectionManager.instance.connectedPeerIds;
    final targets = <AgentTarget>[];
    final host = hostId == null ? null : byId[hostId];
    if (host != null && !host.isBlocked) {
      targets.add(AgentTarget(
        peerId: host.id,
        name: host.deviceName,
        online: true,
      ));
      targets.addAll(await _workerTargets(host.id));
    }
    final others = peers.where((peer) {
      if (peer.isBlocked || peer.id == hostId) return false;
      return connected.contains(peer.id);
    });
    final probed = await Future.wait(others.map((peer) async {
      final listed = await PeerAgentClientService.instance.manageAgents(
        peerId: peer.id,
        op: 'engines',
        timeout: const Duration(seconds: 8),
      );
      return listed.ok && !listed.unsupported ? peer : null;
    }));
    for (final peer in probed) {
      if (peer != null) {
        targets.add(AgentTarget(
          peerId: peer.id,
          name: peer.deviceName,
          online: true,
        ));
      }
    }
    if (!mounted) return;
    final draft = AddAgentInstanceScreen.draft;
    final presetNode = widget.presetNodeId;
    final preferred = presetNode != null && hostId != null
        ? targetKey(hostId, presetNode)
        : (widget.presetPeerId ?? draft?.targetKey ?? hostId);
    final selected = targets.any((target) => target.key == preferred)
        ? preferred
        : (targets.isEmpty ? null : targets.first.key);
    setState(() => _targets = targets);
    if (host != null) _watchWorkers(host.id);
    if (selected != null) {
      await _selectTarget(selected, restoreDraft: draft?.targetKey == selected);
    } else if (mounted) {
      setState(() => _loading = false);
    }
  }

  /// 主机名单里的工作节点，来自通讯录的工作节点节。
  Future<List<AgentTarget>> _workerTargets(String hostId) async {
    if (!getIt.isRegistered<ContactsDirectory>()) return const [];
    final directory = getIt<ContactsDirectory>()..start();
    if (directory.latest?.host?.id != hostId ||
        directory.latest!.inSection(ContactSection.worker).isEmpty) {
      await directory
          .refresh()
          .timeout(const Duration(seconds: 5), onTimeout: () {});
    }
    return _workersIn(directory.latest, hostId);
  }

  List<AgentTarget> _workersIn(ContactsView? view, String hostId) {
    if (view == null || view.host?.id != hostId) return const [];
    return [
      for (final device in view.inSection(ContactSection.worker))
        if (device.nodeId != null)
          AgentTarget(
            peerId: hostId,
            nodeId: device.nodeId,
            name: device.peer.deviceName,
            online: device.online,
          ),
    ];
  }

  /// 节点上下线时刷新选项；正在用的节点掉线，提交按钮跟着置灰。
  void _watchWorkers(String hostId) {
    if (!getIt.isRegistered<ContactsDirectory>()) return;
    _directorySub ??= getIt<ContactsDirectory>().snapshots.listen((view) {
      if (!mounted) return;
      final workers = {
        for (final worker in _workersIn(view, hostId)) worker.key: worker,
      };
      setState(() {
        _targets = [
          for (final target in _targets)
            if (target.nodeId == null)
              target
            else
              workers.remove(target.key) ??
                  AgentTarget(
                    peerId: target.peerId,
                    nodeId: target.nodeId,
                    name: target.name,
                    online: false,
                  ),
          ...workers.values,
        ];
        final current = _target;
        if (current != null) {
          _target = _targets.where((t) => t.key == current.key).firstOrNull ??
              current;
        }
      });
    });
  }

  Future<void> _selectTarget(String key, {bool restoreDraft = false}) async {
    final target = _targets.where((item) => item.key == key).firstOrNull;
    if (target == null) return;
    if (_target != null && _target!.key != key) {
      AddAgentInstanceScreen.draft = null;
      restoreDraft = false;
    }
    final peerId = target.peerId;
    final nodeId = target.nodeId;
    setState(() {
      _loading = true;
      _error = '';
      _target = target;
      _engines = const [];
      _engineId = null;
      _sessionMode = null;
      _cwd = '';
      _instanceCwds = const [];
      _nameTouched = false;
      for (final field in _extraControllers) {
        field.dispose();
      }
      _extraControllers.clear();
    });
    final service = PeerAgentClientService.instance;
    if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
      final peer = await PeerStorageService().getPeerById(peerId);
      if (peer != null) {
        await PeerConnectionManager.instance.connectToPeer(peer);
      }
    }
    final listed = await service.manageAgents(
      peerId: peerId,
      op: 'engines',
      nodeId: nodeId,
    );
    if (listed.nodeOffline) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = AppLocalizations.of(context).addAgent_nodeOffline(target.name);
      });
      return;
    }
    final agents = await service.manageAgents(
      peerId: peerId,
      op: 'list',
      nodeId: nodeId,
    );
    final home = await service.browseRemoteFs(peerId: peerId, nodeId: nodeId);
    final history = await _readHistory(peerId, nodeId);
    if (!mounted || _target?.key != key) return;
    final engines = sortEnginesUnavailableLast(
      listed.engines,
      (engine) => engine.available,
    );
    final draft = restoreDraft ? AddAgentInstanceScreen.draft : null;
    final firstReady = engines.where((engine) => engine.available).firstOrNull;
    final engineId = engines.any((engine) => engine.id == draft?.engineId)
        ? draft?.engineId
        : firstReady?.id;
    setState(() {
      _engines = engines;
      _engineId = engineId;
      _history = history;
      _instanceCwds = [
        for (final agent in agents.agents)
          if (agent.cwd.trim().isNotEmpty) agent.cwd,
      ];
      _cwd = (draft?.cwd.trim().isNotEmpty ?? false)
          ? draft!.cwd
          : (home.ok ? home.path : '');
      _nameTouched = draft?.nameTouched ?? false;
      _loading = false;
      if (draft != null) {
        for (final extra in draft.extras) {
          _extraControllers.add(TextEditingController(text: extra));
        }
      }
    });
    _applySessionDefault();
    if (draft != null && draft.nameTouched) {
      _applyingName = true;
      _nameController.text = draft.name;
      _applyingName = false;
      _nameTouched = true;
    } else {
      _applyNameFromCwd();
    }
  }

  void _applySessionDefault() {
    final engine = _selectedEngine;
    if (engine == null || engine.sessionModes.isEmpty) {
      _sessionMode = null;
      return;
    }
    final draft = AddAgentInstanceScreen.draft;
    final wanted = draft?.sessionMode;
    if (wanted != null &&
        engine.sessionModes.any((mode) => mode.value == wanted)) {
      _sessionMode = wanted;
      return;
    }
    final fallback = engine.defaultSessionMode;
    _sessionMode = engine.sessionModes.any((mode) => mode.value == fallback)
        ? fallback
        : engine.sessionModes.first.value;
  }

  PeerEngineEntry? get _selectedEngine {
    for (final engine in _engines) {
      if (engine.id == _engineId) return engine;
    }
    return null;
  }

  void _applyNameFromCwd() {
    if (_nameTouched) return;
    _applyingName = true;
    _nameController.text = directoryBasename(_cwd);
    _applyingName = false;
  }

  void _setCwd(String path) {
    setState(() => _cwd = path);
    _applyNameFromCwd();
  }

  Future<HostFsBrowseResult> _browse(String? path) async {
    final peerId = _peerId;
    if (peerId == null) throw StateError('offline');
    final result = await PeerAgentClientService.instance.browseRemoteFs(
      peerId: peerId,
      path: path,
      nodeId: _nodeId,
    );
    if (!result.ok) throw Exception(result.error ?? 'browse failed');
    return HostFsBrowseResult(
      path: result.path,
      parent: result.parent,
      entries: [
        for (final entry in result.entries)
          HostFsBrowseEntry(name: entry.name, path: entry.path),
      ],
    );
  }

  Future<void> _pickDirectory({TextEditingController? into}) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showHostDirectoryPicker(
      context: context,
      browse: _browse,
      initialPath: into?.text.trim().isNotEmpty == true ? into!.text : _cwd,
      title: l10n.peerSettings_chooseWorkspace,
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    if (into != null) {
      setState(() => into.text = picked);
    } else {
      _setCwd(picked);
    }
  }

  List<String> get _suggestions => mergeCwdSuggestions(_history, _instanceCwds);

  bool get _canSubmit {
    final engine = _selectedEngine;
    return !_submitting &&
        !_loading &&
        _peerId != null &&
        engine != null &&
        engine.available &&
        _hostOnline &&
        _cwd.trim().isNotEmpty;
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final peerId = _peerId;
    final nodeId = _nodeId;
    final engine = _selectedEngine;
    if (peerId == null || engine == null || !_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = '';
    });
    final extras = cleanAdditionalDirectories(
      _cwd,
      _extraControllers.map((field) => field.text),
    );
    final name = _nameController.text.trim();
    final created = await PeerAgentClientService.instance.createAgent(
      peerId: peerId,
      nodeId: nodeId,
      engine: engine.id,
      cwd: _cwd.trim(),
      name: name.isEmpty ? null : name,
      sessionMode: _sessionMode,
      additionalDirectories: extras,
    );
    if (!mounted) return;
    if (!created.ok || (created.createdAgentId ?? '').isEmpty) {
      setState(() {
        _submitting = false;
        _error = created.nodeOffline
            ? l10n.addAgent_nodeOffline(_target?.name ?? '')
            : (created.error ?? l10n.pouch_loginFailed);
      });
      return;
    }
    final history = rememberCwd(_history, _cwd);
    await _writeHistory(peerId, nodeId, history);
    await PeerAgentClientService.instance.refreshAgentList(peerId);
    final local = await _waitLocal(peerId, created.createdAgentId!);
    if (!mounted) return;
    _submitted = true;
    AddAgentInstanceScreen.draft = null;
    if (local == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.addAgent_syncing)),
      );
      _close();
      return;
    }
    final opened = widget.onCreated;
    if (opened != null) {
      opened(local);
      return;
    }
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          agentId: local.id,
          agentName: local.name,
          agentAvatar: local.avatar,
        ),
      ),
    );
  }

  Future<RemoteAgent?> _waitLocal(String peerId, String remoteId) async {
    final db = getIt<LocalDatabaseService>();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final agents = await db.getAllRemoteAgents();
      for (final agent in agents) {
        if (agent.remoteAgentId == remoteId && agent.sourcePeerId == peerId) {
          return agent;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  void _close() {
    final close = widget.onClose;
    if (close != null) {
      close();
      return;
    }
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  Future<List<String>> _readHistory(String peerId, String? nodeId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(cwdHistoryKey(peerId, nodeId)) ?? const [];
    final seen = <String>{};
    final out = <String>[];
    for (final item in raw) {
      final key = normalizeCwd(item);
      if (key.isEmpty || !seen.add(key)) continue;
      out.add(item.trim());
      if (out.length == 30) break;
    }
    return out;
  }

  Future<void> _writeHistory(
    String peerId,
    String? nodeId,
    List<String> paths,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      cwdHistoryKey(peerId, nodeId),
      paths.take(30).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final engine = _selectedEngine;
    final anyAvailable = _engines.any((item) => item.available);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.addAgent_title),
        automaticallyImplyLeading: !widget.embedded,
        actions: [
          if (widget.onClose != null)
            IconButton(
              onPressed: _close,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(l10n.addAgent_node,
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                _deviceField(l10n),
                if (_peerId == null) ...[
                  const SizedBox(height: 12),
                  Text(l10n.pouch_hostOffline),
                ] else ...[
                  const SizedBox(height: 20),
                  if (!anyAvailable)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        l10n.addAgent_noEngines,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  Text(l10n.addAgent_engine,
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  AgentEngineDropdown(
                    engines: _engines,
                    selectedId: _engineId,
                    enabled: !_submitting,
                    onSelected: (engine) {
                      if (!_hostOnline) return;
                      setState(() {
                        _engineId = engine.id;
                        AddAgentInstanceScreen.draft = null;
                        _applySessionDefault();
                      });
                    },
                    onUnavailable: (engine) => unawaited(_openSetup(engine)),
                  ),
                ],
                if (engine != null &&
                    engine.available &&
                    engine.sessionModes.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(
                    l10n.addAgent_sessionMode,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  RadioGroup<String>(
                    groupValue: _sessionMode,
                    onChanged: (value) {
                      if (_submitting || value == null) return;
                      setState(() => _sessionMode = value);
                    },
                    child: Column(
                      children: [
                        for (final mode in engine.sessionModes)
                          RadioListTile<String>(
                            contentPadding: EdgeInsets.zero,
                            value: mode.value,
                            title: Text(mode.displayName),
                            subtitle: mode.description.isEmpty
                                ? null
                                : Text(mode.description),
                          ),
                      ],
                    ),
                  ),
                ],
                if (engine != null && engine.available) ...[
                  const SizedBox(height: 20),
                  TextField(
                    controller: _nameController,
                    decoration: InputDecoration(labelText: l10n.addAgent_name),
                  ),
                  const SizedBox(height: 16),
                  Text(l10n.addAgent_cwd,
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  _pathRow(
                    text:
                        _cwd.isEmpty ? l10n.peerSettings_chooseWorkspace : _cwd,
                    muted: _cwd.isEmpty,
                    onBrowse: () => _pickDirectory(),
                  ),
                  if (_suggestions.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final path in _suggestions)
                          ActionChip(
                            label: Text(path, overflow: TextOverflow.ellipsis),
                            onPressed: () => _setCwd(path),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    l10n.addAgent_additional,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < _extraControllers.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _pathRow(
                        text: _extraControllers[i].text.isEmpty
                            ? l10n.peerSettings_chooseWorkspace
                            : _extraControllers[i].text,
                        muted: _extraControllers[i].text.isEmpty,
                        onBrowse: () =>
                            _pickDirectory(into: _extraControllers[i]),
                        onDelete: () {
                          setState(() {
                            _extraControllers.removeAt(i).dispose();
                          });
                        },
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _extraControllers.add(TextEditingController());
                        });
                      },
                      icon: const Icon(Icons.add),
                      label: Text(l10n.addAgent_addDirectory),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _canSubmit ? _submit : null,
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.addAgent_submit),
                  ),
                ],
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _deviceField(AppLocalizations l10n) {
    if (_targets.isEmpty) return Text(l10n.pouch_hostOffline);
    return Column(
      children: [
        for (final target in _targets)
          Builder(builder: (context) {
            final online = _isOnline(target);
            final selectable = online || target.nodeId == null;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              selected: target.key == _target?.key,
              enabled: selectable,
              leading: Icon(
                target.nodeId == null
                    ? Icons.dns_outlined
                    : Icons.memory_outlined,
              ),
              title: Text(target.name),
              subtitle: Text(
                target.nodeId == null
                    ? l10n.contacts_host
                    : l10n.contacts_workerNodes,
              ),
              trailing: EngineStatusChip(
                label: online ? l10n.addAgent_online : l10n.addAgent_offline,
                positive: online,
              ),
              onTap: _submitting || !selectable
                  ? null
                  : () => unawaited(_selectTarget(target.key)),
            );
          }),
      ],
    );
  }

  Future<void> _openSetup(PeerEngineEntry engine) async {
    final again = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EngineSetupScreen(
          engine: engine,
          hostOnline: _hostOnline,
          nodeName: _nodeId == null ? null : _target?.name,
        ),
      ),
    );
    final key = _target?.key;
    if (again == true && key != null && mounted) {
      await _selectTarget(key, restoreDraft: true);
    }
  }

  Widget _pathRow({
    required String text,
    required bool muted,
    required VoidCallback onBrowse,
    VoidCallback? onDelete,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: muted ? const TextStyle(color: Colors.grey) : null,
          ),
        ),
        TextButton(
            onPressed: onBrowse,
            child: Text(AppLocalizations.of(context).addAgent_browse)),
        if (onDelete != null)
          IconButton(onPressed: onDelete, icon: const Icon(Icons.close)),
      ],
    );
  }
}
