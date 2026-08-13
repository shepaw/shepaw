import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../models/agent_memory_entry.dart';
import '../models/remote_agent.dart';
import '../peer/services/peer_attachment_placement.dart';
import '../services/agent_memory_biz_service.dart';
import '../services/cognition_service.dart';
import '../services/logger_service.dart';
import '../services/store_open_service.dart';
import '../storage/device_identity.dart';
import '../storage/runtime_paths.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import '../utils/layout_utils.dart';
import '../widgets/storage/store_file_list_avatar.dart';
import 'agent_memory_detail_screen.dart';
import 'storage_browser_screen.dart';

/// Agent / Group 运行时上下文。
///
/// Agent：记忆、Soul、产物、附件。
/// Group：仅产物与附件（群没有 soul；人格在各成员自己的储物袋）。
class AgentRuntimeContextScreen extends StatefulWidget {
  const AgentRuntimeContextScreen({
    super.key,
    required this.ownerId,
    required this.displayName,
    this.agent,
  });

  /// `runtime/<ownerId>/` 第一段（agentId 或 groupId）。
  final String ownerId;

  final String displayName;

  /// 非空时「记忆」Tab 可读结构化记忆库。
  final RemoteAgent? agent;

  @override
  State<AgentRuntimeContextScreen> createState() =>
      _AgentRuntimeContextScreenState();
}

class _AgentRuntimeContextScreenState extends State<AgentRuntimeContextScreen>
    with SingleTickerProviderStateMixin {
  static const _tag = 'AgentRuntimeCtx';

  late final TabController _tabs;
  final _log = LoggerService();

  String? _soul;
  bool _soulLoading = true;
  List<AgentMemoryEntry> _memories = const [];
  bool _memoryLoading = true;
  List<_RuntimeFile> _artifacts = const [];
  List<_RuntimeFile> _attachments = const [];
  bool _filesLoading = true;
  String? _filesError;
  String _deviceId = '';
  /// Peer 缓存：列本机磁盘上的宿主 device 树。
  bool _preferLocalCache = false;
  /// runtime 目录第一段（peer 用 remoteAgentId）。
  String _runtimeOwnerId = '';

  bool get _zh =>
      Localizations.localeOf(context).languageCode.startsWith('zh');

  String get _effectiveOwnerId =>
      _runtimeOwnerId.isNotEmpty ? _runtimeOwnerId : widget.ownerId;

  bool get _isGroupContext => widget.agent == null;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _isGroupContext ? 2 : 4, vsync: this);
    _loadAll();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    if (_isGroupContext) {
      await _loadFiles();
      return;
    }
    await Future.wait([_loadSoul(), _loadMemories(), _loadFiles()]);
  }

  Future<void> _loadSoul() async {
    setState(() => _soulLoading = true);
    try {
      final text =
          await CognitionService.instance.getAgentSoul(widget.ownerId);
      if (!mounted) return;
      setState(() {
        _soul = text;
        _soulLoading = false;
      });
    } catch (e) {
      _log.warning('load soul failed: $e', tag: _tag);
      if (!mounted) return;
      setState(() {
        _soul = null;
        _soulLoading = false;
      });
    }
  }

  Future<void> _loadMemories() async {
    final agent = widget.agent;
    if (agent == null) {
      setState(() {
        _memories = const [];
        _memoryLoading = false;
      });
      return;
    }
    setState(() => _memoryLoading = true);
    try {
      final list =
          await AgentMemoryBizService().getAllMemories(agent.id);
      if (!mounted) return;
      setState(() {
        _memories = list;
        _memoryLoading = false;
      });
    } catch (e) {
      _log.warning('load memories failed: $e', tag: _tag);
      if (!mounted) return;
      setState(() {
        _memories = const [];
        _memoryLoading = false;
      });
    }
  }

  Future<void> _loadFiles() async {
    setState(() {
      _filesLoading = true;
      _filesError = null;
    });
    try {
      var deviceId = await DeviceIdentity.deviceId();
      var ownerId = widget.ownerId;
      var preferLocalCache = false;
      final agent = widget.agent;
      if (agent != null && agent.isPeerAgent) {
        final placement = await resolvePeerAttachmentPlacement(
          agent: agent,
          localChannelId: '',
        );
        if (placement != null) {
          deviceId = placement.deviceId;
          ownerId = placement.ownerId;
          preferLocalCache = true;
        } else {
          final remote = agent.remoteAgentId?.trim();
          if (remote != null && remote.isNotEmpty) ownerId = remote;
        }
      }
      final root = RuntimePaths.runtimeRoot(ownerId);
      final entries = await StoreService.instance.listDevice(
        deviceId: deviceId,
        space: StoreSpace.runtime,
        prefix: '$root/',
        limit: 5000,
        preferLocalCache: preferLocalCache,
      );
      final arts = <_RuntimeFile>[];
      final atts = <_RuntimeFile>[];
      for (final e in entries) {
        if (e.isDir) continue;
        final path = e.path.replaceAll('\\', '/');
        final uri = storeUriWithRef(StoreSpace.runtime, deviceId, path);
        final file = _RuntimeFile(
          path: path,
          size: e.size,
          mtimeMs: e.mtimeMs,
          uri: uri,
        );
        if (path.contains('/artifacts/')) {
          arts.add(file);
        } else if (path.contains('/attachments/')) {
          atts.add(file);
        }
      }
      arts.sort((a, b) => b.mtimeMs.compareTo(a.mtimeMs));
      atts.sort((a, b) => b.mtimeMs.compareTo(a.mtimeMs));
      if (!mounted) return;
      setState(() {
        _deviceId = deviceId;
        _runtimeOwnerId = ownerId;
        _preferLocalCache = preferLocalCache;
        _artifacts = arts;
        _attachments = atts;
        _filesLoading = false;
      });
    } catch (e) {
      _log.warning('load runtime files failed: $e', tag: _tag);
      if (!mounted) return;
      setState(() {
        _filesLoading = false;
        _filesError = '$e';
      });
    }
  }

  void _openMemoryDetail() {
    final agent = widget.agent;
    if (agent == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentMemoryDetailScreen(agent: agent),
      ),
    );
  }

  void _openRuntimeBrowser() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StorageBrowserScreen(
          deviceId: _deviceId.isNotEmpty ? _deviceId : null,
          preferLocalCache: _preferLocalCache,
          readOnly: _preferLocalCache,
          initialSpace: StoreSpace.runtime,
          initialPath: RuntimePaths.runtimeRoot(_effectiveOwnerId),
          title: _zh
              ? '${widget.displayName} · runtime'
              : '${widget.displayName} · runtime',
        ),
      ),
    );
  }

  Future<void> _openFile(_RuntimeFile file) async {
    await StoreOpenService.instance.openStoreUri(context, file.uri);
  }

  Future<void> _copyPath(_RuntimeFile file) async {
    await Clipboard.setData(ClipboardData(text: file.uri));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_zh ? '路径已复制' : 'Path copied')),
    );
  }

  Future<void> _shareLink(_RuntimeFile file) async {
    final name = file.path.split('/').last;
    final md = formatStoreMarkdownLink(name, file.uri);
    if (LayoutUtils.isDesktopLayout(context)) {
      await Clipboard.setData(ClipboardData(text: md));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_zh ? '分享链接已复制' : 'Share link copied')),
      );
      return;
    }
    await Share.share(md, subject: name);
  }

  Future<void> _showFileActions(_RuntimeFile file) async {
    final name = file.path.split('/').last;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(file.uri, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(_zh ? '复制路径' : 'Copy path'),
              onTap: () {
                Navigator.of(ctx).pop();
                _copyPath(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share_outlined),
              title: Text(_zh ? '分享链接' : 'Share link'),
              onTap: () {
                Navigator.of(ctx).pop();
                _shareLink(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: Text(_zh ? '打开' : 'Open'),
              onTap: () {
                Navigator.of(ctx).pop();
                _openFile(file);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_zh
            ? '${widget.displayName} · 上下文'
            : '${widget.displayName} · Context'),
        actions: [
          IconButton(
            tooltip: _zh ? '在储物袋中打开' : 'Open in storage browser',
            icon: const Icon(Icons.folder_open_outlined),
            onPressed: _openRuntimeBrowser,
          ),
          IconButton(
            tooltip: _zh ? '刷新' : 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loadAll,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: [
            if (!_isGroupContext) Tab(text: _zh ? '记忆' : 'Memory'),
            if (!_isGroupContext) const Tab(text: 'Soul'),
            Tab(text: _zh ? '产物' : 'Artifacts'),
            Tab(text: _zh ? '附件' : 'Attachments'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          if (!_isGroupContext) _buildMemoryTab(colorScheme),
          if (!_isGroupContext) _buildSoulTab(colorScheme),
          _buildFilesTab(
            colorScheme,
            files: _artifacts,
            emptyZh: '暂无产物（写入 runtime/…/artifacts/）',
            emptyEn: 'No artifacts yet',
          ),
          _buildFilesTab(
            colorScheme,
            files: _attachments,
            emptyZh: '暂无附件（写入 runtime/…/attachments/）',
            emptyEn: 'No attachments yet',
          ),
        ],
      ),
    );
  }

  Widget _buildMemoryTab(ColorScheme colorScheme) {
    if (widget.agent == null) {
      return _emptyBody(
        _zh ? '此上下文无关联 Agent，无法读取结构化记忆库' : 'No agent bound for memory DB',
      );
    }
    if (_memoryLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _loadMemories,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.psychology_outlined, color: colorScheme.primary),
            title: Text(_zh ? '完整记忆管理' : 'Full memory manager'),
            subtitle: Text(
              _zh
                  ? '共 ${_memories.length} 条 · 权威在储物袋 memory/'
                  : '${_memories.length} entries · pouch memory/ is authoritative',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openMemoryDetail,
          ),
          const Divider(),
          if (_memories.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: _emptyBody(_zh ? '暂无记忆' : 'No memories yet'),
            )
          else
            ..._memories.take(50).map((m) {
              final when = DateFormat.yMMMd().add_Hm().format(
                    DateTime.fromMillisecondsSinceEpoch(m.createdAt),
                  );
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: colorScheme.outlineVariant),
                ),
                child: ListTile(
                  title: Text(
                    m.memoryContent,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${m.memoryType.name} · $when',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  onTap: _openMemoryDetail,
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildSoulTab(ColorScheme colorScheme) {
    if (_soulLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final text = (_soul ?? '').trim();
    if (text.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadSoul,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.4,
              child: _emptyBody(_zh ? '尚未写入 Soul' : 'Soul is empty'),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadSoul,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _zh
                ? '来自储物袋 memory/<agent>/soul.md；runtime/soul.md 为镜像'
                : 'From pouch memory/<agent>/soul.md; runtime/soul.md is a mirror',
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          SelectableText(
            text,
            style: const TextStyle(fontSize: 15, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildFilesTab(
    ColorScheme colorScheme, {
    required List<_RuntimeFile> files,
    required String emptyZh,
    required String emptyEn,
  }) {
    if (_filesLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_filesError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_filesError!, textAlign: TextAlign.center),
        ),
      );
    }
    if (files.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadFiles,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.4,
              child: _emptyBody(_zh ? emptyZh : emptyEn),
            ),
          ],
        ),
      );
    }
    final fmt = DateFormat.yMMMd().add_Hm();
    final root = RuntimePaths.runtimeRoot(_effectiveOwnerId);
    return RefreshIndicator(
      onRefresh: _loadFiles,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: files.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, i) {
          final f = files[i];
          var rel = f.path;
          if (rel.startsWith('$root/')) {
            rel = rel.substring(root.length + 1);
          }
          final name = rel.split('/').last;
          final when = fmt.format(
            DateTime.fromMillisecondsSinceEpoch(f.mtimeMs),
          );
          return ListTile(
            leading: StoreFileListAvatar(
              deviceId: _deviceId,
              space: StoreSpace.runtime,
              path: f.path,
              sizeBytes: f.size,
            ),
            title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '$rel · ${_formatSize(f.size)} · $when',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: () => _openFile(f),
            onLongPress: () => _showFileActions(f),
          );
        },
      ),
    );
  }

  Widget _emptyBody(String message) {
    return Center(
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _RuntimeFile {
  const _RuntimeFile({
    required this.path,
    required this.size,
    required this.mtimeMs,
    required this.uri,
  });

  final String path;
  final int size;
  final int mtimeMs;
  final String uri;
}
