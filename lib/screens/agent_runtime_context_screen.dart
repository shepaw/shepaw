import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../models/remote_agent.dart';
import '../peer/services/peer_attachment_placement.dart';
import '../services/logger_service.dart';
import '../services/store_open_service.dart';
import '../storage/device_identity.dart';
import '../storage/runtime_paths.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import '../utils/layout_utils.dart';
import '../widgets/storage/store_file_list_avatar.dart';
import 'storage_browser_screen.dart';

/// Agent / Group 运行时上下文：产物与附件。
///
/// Soul / 记忆已拆到 Agent 详情的独立入口（可查看与修改）。
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

  /// 非空时用于解析 peer agent 的本机缓存路径。
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

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _loadFiles();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
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
        computeHash: false,
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
            ? '${widget.displayName} · 产物与附件'
            : '${widget.displayName} · Artifacts'),
        actions: [
          IconButton(
            tooltip: _zh ? '在储物袋中打开' : 'Open in storage browser',
            icon: const Icon(Icons.folder_open_outlined),
            onPressed: _openRuntimeBrowser,
          ),
          IconButton(
            tooltip: _zh ? '刷新' : 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loadFiles,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: _zh ? '产物' : 'Artifacts'),
            Tab(text: _zh ? '附件' : 'Attachments'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
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
