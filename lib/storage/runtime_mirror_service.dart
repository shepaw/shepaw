import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../peer/services/peer_attachment_placement.dart';
import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'memory_paths.dart';
import 'runtime_paths.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// SQLite / memory-store → runtime 单向镜像（docs/CLIENT_PROFILES.md）。
///
/// 失败 fail-open：不影响聊天；永不从文件回灌权威。
class RuntimeMirrorService {
  RuntimeMirrorService._();
  static final RuntimeMirrorService instance = RuntimeMirrorService._();

  static const _tag = 'RuntimeMirror';
  final _log = LoggerService();
  final _pendingSession = <String, _PendingSessionMirror>{};
  final _pendingMemory = <String, Timer>{};
  /// 空闲 debounce。一次会话内的连续写（流式 flush、批量落库、群成员
  /// 逐条入库）合并成一次全量镜像。
  Duration debounce = const Duration(seconds: 2);

  /// 待写镜像最长落后多久就强制落盘。
  ///
  /// 流式回合里消息持续到达，纯空闲 debounce 的窗口会被一直重置、直到回
  /// 合结束才写。靠这个上限保证镜像不会一直停在回合开始时的状态。
  Duration maxStaleness = const Duration(seconds: 10);
  /// 已建过 scaffold 的 `device::owner::persona`（见 [ensureRuntimeScaffold]）。
  final _scaffolded = <String>{};
  /// channel → 镜像落盘路由（见 [_resolveAndScheduleSession]）。
  final _routeCache = <String, _MirrorRoute>{};
  /// owner → 最近一次镜像（见 [_enqueueMirror]）。
  final _mirrorTails = <String, Future<void>>{};

  /// session.json 最近窗口条数；超出则滚动到 archive。
  static const sessionWindowSize = 100;
  /// 触发滚动的消息条数阈值（含窗口外）。
  static const sessionRollMessageThreshold = 200;
  /// 触发滚动的序列化体积阈值（字节）。
  static const sessionRollBytesThreshold = 256 * 1024;

  /// 消息落库后的轻量入口：解析 channel → owner，再 debounce 镜像。
  void onMessageCreated(String channelId) {
    unawaited(_resolveAndScheduleSession(channelId));
  }

  Future<void> _resolveAndScheduleSession(String channelId) async {
    // 同一会话里这个路由结果不会变，但每条消息都要过一遍：缓存后省掉
    // getChannelById + getRemoteAgentById（+ peer 解析）三次 await。
    final cached = _routeCache[channelId];
    if (cached != null) {
      scheduleSessionMirror(
        ownerId: cached.ownerId,
        channelId: cached.channelId,
        deviceId: cached.deviceId,
        messagesChannelId: cached.messagesChannelId,
      );
      return;
    }
    try {
      final db = LocalDatabaseService();
      final ch = await db.getChannelById(channelId);
      final agentId = ch?.members
              .where((m) => m.type == 'agent')
              .map((m) => m.id)
              .firstOrNull ??
          channelId;

      // Peer 隧道：本机缓存与宿主 URI 对齐（device=对端 fingerprint，
      // path channel=peer__…；消息仍从本地 SQLite channel 读取）。
      try {
        final agent = await db.getRemoteAgentById(agentId);
        if (agent != null && agent.isPeerAgent) {
          final peer = await resolvePeerAttachmentPlacement(
            agent: agent,
            localChannelId: channelId,
          );
          if (peer != null) {
            _routeCache[channelId] = _MirrorRoute(
              ownerId: peer.ownerId,
              channelId: peer.channelId,
              deviceId: peer.deviceId,
              messagesChannelId: channelId,
            );
            scheduleSessionMirror(
              ownerId: peer.ownerId,
              channelId: peer.channelId,
              deviceId: peer.deviceId,
              messagesChannelId: channelId,
            );
            return;
          }
        }
      } catch (_) {
        /* fall through */
      }

      final ownerId = RuntimePaths.resolveOwnerId(
        agentId: agentId,
        channelId: channelId,
        channelType: ch?.type,
        parentGroupId: ch?.parentGroupId,
      );
      _routeCache[channelId] = _MirrorRoute(ownerId: ownerId, channelId: channelId);
      scheduleSessionMirror(ownerId: ownerId, channelId: channelId);
    } catch (e) {
      // 解析失败：不缓存路由，下次消息再试一次。
      scheduleSessionMirror(ownerId: channelId, channelId: channelId);
    }
  }

  /// store 切换 / 重登录 / 快照导入后调用：落盘路由可能整体变了。
  void invalidateMirrorRoute([String? channelId]) {
    if (channelId == null) {
      _routeCache.clear();
    } else {
      _routeCache.remove(channelId);
    }
  }

  /// 消息落库后调用：debounce 刷新该 channel 的 session.json。
  ///
  /// [deviceId] 非空时写入该 device 目录（peer 缓存）；缺省为本机。
  /// [messagesChannelId] 非空时从该 SQLite channel 读消息（peer 本地会话 id），
  /// 落盘路径仍用 [channelId]（宿主 peer__ channel）。
  void scheduleSessionMirror({
    required String ownerId,
    required String channelId,
    String? deviceId,
    String? messagesChannelId,
  }) {
    final key = '${deviceId ?? '_'}::$ownerId::$channelId';
    final existing = _pendingSession[key];
    existing?.timer?.cancel();
    // 已落后超过 [maxStaleness]：不再继续攒，立即写一次。
    if (existing != null &&
        DateTime.now().millisecondsSinceEpoch - existing.firstScheduledAtMs >=
            maxStaleness.inMilliseconds) {
      _pendingSession.remove(key);
      unawaited(_enqueueMirror(ownerId, () => _mirrorSession(
            ownerId: ownerId,
            channelId: channelId,
            deviceId: deviceId,
            messagesChannelId: messagesChannelId,
          )));
      return;
    }
    final pending = _PendingSessionMirror(
      ownerId: ownerId,
      channelId: channelId,
      deviceId: deviceId,
      messagesChannelId: messagesChannelId,
      firstScheduledAtMs: existing?.firstScheduledAtMs ??
          DateTime.now().millisecondsSinceEpoch,
    );
    pending.timer = Timer(debounce, () {
      _pendingSession.remove(key);
      unawaited(_enqueueMirror(ownerId, () => _mirrorSession(
            ownerId: ownerId,
            channelId: channelId,
            deviceId: deviceId,
            messagesChannelId: messagesChannelId,
          )));
    });
    _pendingSession[key] = pending;
  }

  /// 同一 owner 的镜像串行：manifest 是「读回来 → 加一个 channel → 整体
  /// 重写」，两个子会话并发镜像时后写的会覆盖掉前一个刚加的条目。
  ///
  /// _mirrorSession 自己有 try/catch，这里只负责排队。
  Future<void> _enqueueMirror(
    String ownerId,
    Future<void> Function() action,
  ) {
    final prev = _mirrorTails[ownerId] ?? Future<void>.value();
    final done = prev.catchError((Object _) {}).then((_) => action());
    _mirrorTails[ownerId] = done;
    return done;
  }

  /// 立即落盘所有待写的会话镜像。
  ///
  /// debounce 放宽到 2s 后靠它在回合终态、切后台、页面销毁时收敛，保证
  /// 静止时 session.json 一定是最新的。
  Future<void> flushPendingSessions() async {
    if (_pendingSession.isEmpty) return;
    final pending = _pendingSession.values.toList();
    _pendingSession.clear();
    for (final entry in pending) {
      entry.timer?.cancel();
      await _enqueueMirror(entry.ownerId, () => _mirrorSession(
            ownerId: entry.ownerId,
            channelId: entry.channelId,
            deviceId: entry.deviceId,
            messagesChannelId: entry.messagesChannelId,
          ));
    }
  }

  /// 记忆/soul 变更后调用。
  void scheduleMemoryMirror(String ownerId) {
    final key = ownerId;
    _pendingMemory[key]?.cancel();
    _pendingMemory[key] = Timer(debounce, () {
      _pendingMemory.remove(key);
      unawaited(_mirrorMemoryAndSoul(ownerId));
    });
  }

  Future<void> ensureRuntimeScaffold(
    String ownerId, {
    String? deviceId,
    bool? includePersonaMirror,
  }) async {
    final device = deviceId ?? await DeviceIdentity.deviceId();
    final persona =
        includePersonaMirror ?? !await _ownerIsGroupChannel(ownerId);
    // 语义是「不存在才建」，建过之后每次镜像都探 4 遍 store.meta 纯属浪费。
    // persona 进 key：群 owner 与 agent owner 建的 scaffold 内容不同。
    final scaffoldKey = '$device::$ownerId::${persona ? 1 : 0}';
    if (!_scaffolded.add(scaffoldKey)) return;
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      await _ensureRuntimeScaffoldNow(
        device: device,
        ownerId: ownerId,
        persona: persona,
        now: now,
      );
    } catch (e) {
      // 没建成：忘掉，下次镜像再来一遍。
      _scaffolded.remove(scaffoldKey);
      rethrow;
    }
  }

  Future<void> _ensureRuntimeScaffoldNow({
    required String device,
    required String ownerId,
    required bool persona,
    required String now,
  }) async {
    if (persona) {
      await _writeTextIfAbsent(
        device,
        RuntimePaths.soulMd(ownerId),
        '<!-- mirrored soul; authoritative store is cognition/<agent>/soul.md -->\n',
      );
      await _writeTextIfAbsent(
        device,
        RuntimePaths.memoryMd(ownerId),
        '<!-- mirrored memory summary; authoritative store is cognition/<agent>/entries -->\n',
      );
    }
    await _writeTextIfAbsent(
      device,
      RuntimePaths.workspaceMd(ownerId),
      '# Workspace bindings\n\nworkspace_ids: []\n',
    );
    // scaffold 语义是「不存在才建」：这里曾经用 _writeText 无条件覆盖，
    // 于是每次镜像都先把 manifest 清空（channels 写死 {}、workspace_refs
    // 写死 []），再由 _touchManifestChannel 加回当前这一个 channel——
    // 群 owner 下多个子会话共享一份 manifest，除当前会话外的 session_uri
    // 会永久丢失，workspace_refs 也被抹掉。
    await _writeTextIfAbsent(
      device,
      RuntimePaths.contextManifest(ownerId),
      const JsonEncoder.withIndent('  ').convert({
        'schema_version': 1,
        'owner_id': ownerId,
        'source_device': device,
        'updated_at': now,
        if (persona)
          'soul_uri': MemoryPaths.uri(relPath: MemoryPaths.soulMd(ownerId)),
        if (persona)
          'memory_uri': MemoryPaths.uri(relPath: MemoryPaths.entriesDir(ownerId)),
        'workspace_refs': <String>[],
        'channels': <String, dynamic>{},
      }),
    );
  }

  Future<void> _mirrorSession({
    required String ownerId,
    required String channelId,
    String? deviceId,
    String? messagesChannelId,
  }) async {
    try {
      final self = await DeviceIdentity.deviceId();
      final device = deviceId ?? self;
      final isPeerCache = device != self;
      // Peer 缓存只写 session，不在对端 device 树下伪造 soul/memory scaffold。
      if (!isPeerCache) {
        await ensureRuntimeScaffold(ownerId, deviceId: device);
      }
      final loadChannel = messagesChannelId ?? channelId;
      // 读够判定滚动的条数即可：第 201 条起既不参与 shouldRoll 也不进
      // session.json（窗口只有 sessionWindowSize 条）。
      final rows = await LocalDatabaseService().getChannelMessages(
        loadChannel,
        limit: sessionRollMessageThreshold,
        offset: 0,
      );
      // DAO returns newest-first; mirror chronological.
      final chronological = rows.reversed.toList();
      final messages = <Map<String, dynamic>>[];
      for (final row in chronological) {
        final metaRaw = row['metadata'] as String?;
        Map<String, dynamic>? meta;
        if (metaRaw != null && metaRaw.isNotEmpty) {
          try {
            meta = jsonDecode(metaRaw) as Map<String, dynamic>;
          } catch (_) {}
        }
        messages.add({
          'id': row['id'],
          'sender_id': row['sender_id'],
          'sender_type': row['sender_type'],
          'sender_name': row['sender_name'],
          'content': row['content'],
          'message_type': row['message_type'],
          'created_at': row['created_at'],
          if (meta?['pouch_uri'] != null) 'pouch_uri': meta!['pouch_uri'],
        });
      }
      final payload = <String, dynamic>{
        'meta': <String, dynamic>{
          'channel_id': channelId,
          'owner_id': ownerId,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'schema_version': 1,
          'source_device': device,
          'window_size': sessionWindowSize,
          if (isPeerCache) 'placement': 'local_fallback',
          if (messagesChannelId != null && messagesChannelId != channelId)
            'local_channel_id': messagesChannelId,
        },
        'messages': messages,
      };
      // 不缩进：session.json 是跨设备只读上下文 / 分享用的镜像，不是手改
      // 的文件；缩进会让体积和编解码耗时都翻 2–3 倍。
      var body = jsonEncode(payload);
      final shouldRoll = messages.length >= sessionRollMessageThreshold ||
          body.length >= sessionRollBytesThreshold;
      if (shouldRoll && messages.length > sessionWindowSize) {
        final ts = DateTime.now()
            .toUtc()
            .toIso8601String()
            .replaceAll(':', '-')
            .replaceAll('.', '-');
        await _writeText(
          device,
          RuntimePaths.sessionArchive(ownerId, channelId, ts),
          body,
        );
        final window = messages.sublist(messages.length - sessionWindowSize);
        payload['messages'] = window;
        final meta = payload['meta'] as Map<String, dynamic>;
        meta['archived_at'] = DateTime.now().toUtc().toIso8601String();
        meta['archive_uri'] = RuntimePaths.uri(
          relPath: RuntimePaths.sessionArchive(ownerId, channelId, ts),
        );
        body = jsonEncode(payload);
      }
      await _writeText(
        device,
        RuntimePaths.sessionJson(ownerId, channelId),
        body,
      );
      if (!isPeerCache) {
        await _touchManifestChannel(device, ownerId, channelId);
      }
    } catch (e) {
      _log.warning('session mirror failed owner=$ownerId ch=$channelId: $e',
          tag: _tag);
    }
  }

  Future<void> _mirrorMemoryAndSoul(String ownerId) async {
    try {
      await ensureRuntimeScaffold(ownerId);
      final deviceId = await DeviceIdentity.deviceId();
      // Best-effort exports; empty placeholders OK if DBs unavailable in tests.
      String soul = '';
      String memory = '';
      try {
        // Lazy import path via dynamic DB reads would create cycles; keep text
        // export thin — callers may pass content via [mirrorSoul]/[mirrorMemory].
      } catch (_) {}
      final header =
          '<!-- updated_at: ${DateTime.now().toUtc().toIso8601String()} -->\n';
      if (soul.isNotEmpty) {
        await _writeText(
            deviceId, RuntimePaths.soulMd(ownerId), '$header$soul\n');
      }
      if (memory.isNotEmpty) {
        await _writeText(
            deviceId, RuntimePaths.memoryMd(ownerId), '$header$memory\n');
      }
    } catch (e) {
      _log.warning('memory mirror failed owner=$ownerId: $e', tag: _tag);
    }
  }

  /// 显式写入 soul 镜像正文。
  Future<void> mirrorSoul(String ownerId, String soul) async {
    try {
      final deviceId = await DeviceIdentity.deviceId();
      final header =
          '<!-- updated_at: ${DateTime.now().toUtc().toIso8601String()} -->\n';
      await _writeText(
          deviceId, RuntimePaths.soulMd(ownerId), '$header$soul\n');
      await ensureRuntimeScaffold(ownerId);
    } catch (e) {
      _log.warning('soul mirror failed owner=$ownerId: $e', tag: _tag);
    }
  }

  /// 显式写入 memory 镜像正文。
  Future<void> mirrorMemory(String ownerId, String memoryMd) async {
    try {
      final deviceId = await DeviceIdentity.deviceId();
      final header =
          '<!-- updated_at: ${DateTime.now().toUtc().toIso8601String()} -->\n';
      await _writeText(
          deviceId, RuntimePaths.memoryMd(ownerId), '$header$memoryMd\n');
      await ensureRuntimeScaffold(ownerId);
    } catch (e) {
      _log.warning('memory.md mirror failed owner=$ownerId: $e', tag: _tag);
    }
  }

  /// 已经写进 manifest 的 (device, owner, channel)。
  ///
  /// manifest 里一个 channel 的条目只有 session_uri，落一次就不再变；重复
  /// 「分块读回整份 manifest → decode → 整体重写」纯属浪费。依赖
  /// ensureRuntimeScaffold 不再无条件清空 manifest。
  final _registeredManifest = <String>{};

  /// store 切换 / 重登录 / 快照导入后调用：manifest、scaffold 与落盘路由
  /// 都可能被整体换掉，进程内的记忆一并作废。
  void invalidateManifestCache() {
    _registeredManifest.clear();
    _scaffolded.clear();
    _routeCache.clear();
  }

  Future<void> _touchManifestChannel(
    String deviceId,
    String ownerId,
    String channelId,
  ) async {
    final manifestKey = '$deviceId::$ownerId::$channelId';
    if (!_registeredManifest.add(manifestKey)) return;
    try {
      await _touchManifestChannelNow(deviceId, ownerId, channelId);
    } catch (e) {
      // 写失败就忘掉，下次镜像再来一遍。
      _registeredManifest.remove(manifestKey);
      rethrow;
    }
  }

  Future<void> _touchManifestChannelNow(
    String deviceId,
    String ownerId,
    String channelId,
  ) async {
    final rel = RuntimePaths.contextManifest(ownerId);
    Map<String, dynamic> manifest = {
      'schema_version': 1,
      'owner_id': ownerId,
      'source_device': deviceId,
      'channels': <String, dynamic>{},
    };
    try {
      final store = await StoreService.instance.localStore();
      final buf = BytesBuilder(copy: false);
      var offset = 0;
      while (true) {
        final (chunk, size, eof) = await store.read(
          deviceId,
          StoreSpace.runtime,
          rel,
          offset,
          LocalStore.maxReadChunk,
        );
        if (chunk.isNotEmpty) buf.add(chunk);
        offset += chunk.length;
        if (eof || offset >= size) break;
      }
      if (buf.length > 0) {
        manifest = jsonDecode(utf8.decode(buf.takeBytes())) as Map<String, dynamic>;
      }
    } catch (_) {}
    final channels = Map<String, dynamic>.from(
        (manifest['channels'] as Map?)?.cast<String, dynamic>() ?? {});
    channels[channelId] = {
      'session_uri': RuntimePaths.uri(
        relPath: RuntimePaths.sessionJson(ownerId, channelId),
      ),
    };
    manifest['channels'] = channels;
    manifest['updated_at'] = DateTime.now().toUtc().toIso8601String();
    final persona = !await _ownerIsGroupChannel(ownerId);
    if (persona) {
      manifest['soul_uri'] = MemoryPaths.uri(relPath: MemoryPaths.soulMd(ownerId));
      manifest['memory_uri'] = MemoryPaths.uri(relPath: MemoryPaths.entriesDir(ownerId));
    } else {
      manifest.remove('soul_uri');
      manifest.remove('memory_uri');
    }
    // Preserve workspace_refs if already set by WorkspaceBindingService.
    manifest.putIfAbsent('workspace_refs', () => <String>[]);
    await _writeText(
      deviceId,
      rel,
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
  }

  Future<bool> _ownerIsGroupChannel(String ownerId) async {
    try {
      final ch = await LocalDatabaseService().getChannelById(ownerId);
      return ch != null && ch.type == 'group';
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeTextIfAbsent(
      String deviceId, String relPath, String text) async {
    final store = await StoreService.instance.localStore();
    try {
      await store.meta(deviceId, StoreSpace.runtime, relPath);
      return;
    } on StoreException {
      // not found
    }
    await _writeText(deviceId, relPath, text);
  }

  Future<void> _writeText(
      String deviceId, String relPath, String text) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    final hash = crypto.sha256.convert(bytes).toString();
    final store = await StoreService.instance.localStore();
    final (uploadId, _) = await store.writeBegin(
      deviceId: deviceId,
      space: StoreSpace.runtime,
      path: relPath,
      size: bytes.length,
      sha256: hash,
    );
    var offset = 0;
    while (offset < bytes.length) {
      final end = (offset + LocalStore.maxReadChunk) > bytes.length
          ? bytes.length
          : offset + LocalStore.maxReadChunk;
      await store.writeChunk(deviceId, StoreSpace.runtime, uploadId, offset,
          bytes.sublist(offset, end));
      offset = end;
    }
    final (committed, failed) =
        await store.commit(deviceId, StoreSpace.runtime, [uploadId]);
    if (failed.isNotEmpty || committed.isEmpty) {
      throw StateError('runtime mirror commit failed: $failed');
    }
  }
}

/// 待写的会话镜像（[RuntimeMirrorService.flushPendingSessions] 需要回放参数）。
class _PendingSessionMirror {
  _PendingSessionMirror({
    required this.ownerId,
    required this.channelId,
    required this.firstScheduledAtMs,
    this.deviceId,
    this.messagesChannelId,
  });

  final String ownerId;
  final String channelId;
  /// 这一轮合并窗口的起点，用于 [RuntimeMirrorService.maxStaleness] 判定。
  final int firstScheduledAtMs;
  final String? deviceId;
  final String? messagesChannelId;
  Timer? timer;
}

/// SQLite channel → 镜像落盘路径的解析结果。
class _MirrorRoute {
  _MirrorRoute({
    required this.ownerId,
    required this.channelId,
    this.deviceId,
    this.messagesChannelId,
  });

  final String ownerId;
  final String channelId;
  final String? deviceId;
  final String? messagesChannelId;
}
