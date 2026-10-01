import 'package:flutter/material.dart';

import '../peer/models/paired_peer.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/local_agent_hub_models.dart';
import '../services/local_agent_hub_service.dart';
import '../storage/pouch_catalog.dart';
import '../storage/pouch_login.dart';
import '../storage/pouch_login_client.dart';
import '../storage/pouch_session.dart';

/// 先连上这台机器的 agent-hub，再选一个袋子进入。
class PouchLoginScreen extends StatefulWidget {
  const PouchLoginScreen({super.key});

  @override
  State<PouchLoginScreen> createState() => _PouchLoginScreenState();
}

class _PouchLoginScreenState extends State<PouchLoginScreen> {
  final _nameController = TextEditingController();
  final _hub = LocalAgentHubService.instance;

  List<PouchDescriptor> _pouches = const [];
  String _error = '';
  bool _busy = false;

  PouchCatalog get _catalog =>
      PouchCatalog(PouchCatalog.underHub(_hub.hubRoot));

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final local = await _catalog.list();
    if (!mounted) return;
    setState(() => _pouches = local);
    final remote = await requestPouchList().catchError(
      (_) => const <PouchDescriptor>[],
    );
    if (!mounted || remote.isEmpty) return;
    final byId = <String, PouchDescriptor>{
      for (final pouch in remote) pouch.id: pouch,
      for (final pouch in local) pouch.id: pouch,
    };
    setState(() => _pouches = byId.values.toList());
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final pouch = await _catalog.create(name: _nameController.text);
      _nameController.clear();
      await _enter(pouch);
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _error = e.message?.toString() ?? '名字不能为空');
    } catch (e) {
      if (mounted) setState(() => _error = '没能建好袋子');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enter(PouchDescriptor pouch) async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      var detection = await _hub.detect();
      if (detection.presence != LocalHubPresence.running) {
        throw StateError('先在这台机器上启动 agent-hub');
      }
      var peer = await _peerFor(detection.hubFingerprint);
      if (peer == null) {
        await _hub.join();
        detection = await _hub.detect();
        peer = await _peerFor(detection.hubFingerprint);
      }
      if (peer == null) {
        throw StateError('还没连上这台主机');
      }
      final grant = await requestPouchLogin(
        hostPeerId: peer.id,
        pouchId: pouch.id,
      );
      final session = PouchSession(
        hubUrl: _hub.dashboardUrl,
        pouchId: pouch.id,
        pouchName: pouch.name,
        hostPeerId: peer.id,
        token: grant.token,
        sessionId: grant.sessionId,
        expiresAtMs: grant.expiresAtMs,
      );
      await PouchSessionStore(await PouchSessionStore.appFile()).save(session);
      PouchChannel.install(session);
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/home');
    } on LocalHubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '登录失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<PairedPeer?> _peerFor(String? fingerprint) async {
    final fp = fingerprint?.trim() ?? '';
    if (fp.isEmpty) return null;
    return PeerStorageService().getPeerByFingerprint(fp);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('选择储物袋')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            '手机和电脑登录同一只袋子。成功之后登录态会留下来，业务帧用这枚 token 加密。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          if (_pouches.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('还没有袋子'),
            )
          else
            ..._pouches.map(
              (pouch) => ListTile(
                title: Text(pouch.name),
                subtitle: Text(pouch.id),
                enabled: !_busy,
                onTap: () => _enter(pouch),
              ),
            ),
          const SizedBox(height: 24),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: '新袋子的名字',
            ),
            enabled: !_busy,
            onSubmitted: (_) => _create(),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _create,
            child: Text(_busy ? '请稍候' : '新建并登录'),
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(_error,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
