import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../service_locator.dart' show getIt;
import '../services/agent_access_service.dart';
import '../services/noise_identity.dart';
import '../services/remote_agent_service.dart';

/// Search public agents on a Channel Service and request access.
class AgentDiscoveryScreen extends StatefulWidget {
  const AgentDiscoveryScreen({super.key});

  @override
  State<AgentDiscoveryScreen> createState() => _AgentDiscoveryScreenState();
}

class _AgentDiscoveryScreenState extends State<AgentDiscoveryScreen> {
  final _access = AgentAccessService();
  final _baseCtrl = TextEditingController();
  final _queryCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  List<PublicAgentCard> _cards = [];
  bool _loading = false;
  String? _error;
  String? _myFp;
  String? _myPk;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final base = await AgentAccessService.loadChannelBase();
    if (base != null) _baseCtrl.text = base;
    final id = await NoiseIdentity.loadOrCreate();
    if (!mounted) return;
    setState(() {
      _myFp = id.fingerprintHex;
      _myPk = id.publicKeyBase64;
    });
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _queryCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final base = _baseCtrl.text.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      setState(() => _error = '请填写 Channel 服务地址，例如 https://channel.example.com');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AgentAccessService.saveChannelBase(base);
      final cards = await _access.search(
        channelBase: base,
        query: _queryCtrl.text,
      );
      if (!mounted) return;
      setState(() {
        _cards = cards;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _request(PublicAgentCard card) async {
    final base = _baseCtrl.text.trim().replaceAll(RegExp(r'/+$'), '');
    final msgCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('申请接入 ${card.name}'),
        content: TextField(
          controller: msgCtrl,
          decoration: const InputDecoration(
            labelText: '留言（可选）',
            hintText: '简单介绍一下你自己',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      final status = await _access.requestAccess(
        channelBase: base,
        agentId: card.agentId,
        callerName: _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text.trim(),
        message: msgCtrl.text.trim().isEmpty ? null : msgCtrl.text.trim(),
      );
      if (!mounted) return;
      if (status.isApproved) {
        await _import(status);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已提交（${status.status}），可稍后点「刷新状态」')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('申请失败：$e')),
      );
    }
  }

  Future<void> _refreshStatus(PublicAgentCard card) async {
    final base = _baseCtrl.text.trim().replaceAll(RegExp(r'/+$'), '');
    try {
      final status = await _access.getMine(
        channelBase: base,
        agentId: card.agentId,
      );
      if (!mounted) return;
      if (status == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('尚未申请')),
        );
        return;
      }
      if (status.isApproved) {
        await _import(status);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('当前状态：${status.status}')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('查询失败：$e')),
      );
    }
  }

  Future<void> _import(AccessRequestStatus status) async {
    try {
      final agent = await _access.importApproved(
        status: status,
        remoteAgentService: getIt<RemoteAgentService>(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已添加「${agent.name}」，可直接聊天（无需再配对）')),
      );
      Navigator.pop(context, agent);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('发现公开 Agent')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _baseCtrl,
            decoration: const InputDecoration(
              labelText: 'Channel 服务地址',
              hintText: 'https://channel.example.com',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: '你的昵称（申请时展示给 owner）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryCtrl,
                  decoration: const InputDecoration(
                    labelText: '搜索',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _loading ? null : _search,
                child: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('搜索'),
              ),
            ],
          ),
          if (_myFp != null) ...[
            const SizedBox(height: 12),
            Text('我的指纹：$_myFp', style: Theme.of(context).textTheme.bodySmall),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '公钥：${_myPk!.substring(0, 16)}…',
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: '$_myFp\n$_myPk'));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制指纹与公钥')),
                    );
                  },
                  child: const Text('复制'),
                ),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 16),
          if (_cards.isEmpty && !_loading)
            const Text('输入 Channel 地址后搜索公开名片', textAlign: TextAlign.center)
          else
            ..._cards.map(
              (c) => Card(
                child: ListTile(
                  title: Text(c.name.isEmpty ? c.agentId : c.name),
                  subtitle: Text(
                    '${c.online ? "在线" : "离线"} · ${c.description.isEmpty ? c.agentId : c.description}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      TextButton(
                        onPressed: () => _refreshStatus(c),
                        child: const Text('状态'),
                      ),
                      FilledButton(
                        onPressed: () => _request(c),
                        child: const Text('申请'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
