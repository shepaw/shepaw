import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'runtime_paths.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// SQLite → runtime 单向镜像（docs/CLIENT_PROFILES.md）。
///
/// 失败 fail-open：不影响聊天；永不从文件回灌 SQLite。
class RuntimeMirrorService {
  RuntimeMirrorService._();
  static final RuntimeMirrorService instance = RuntimeMirrorService._();

  static const _tag = 'RuntimeMirror';
  final _log = LoggerService();
  final _pendingSession = <String, Timer>{};
  final _pendingMemory = <String, Timer>{};
  Duration debounce = const Duration(milliseconds: 400);

  /// 消息落库后的轻量入口：解析 channel → owner，再 debounce 镜像。
  void onMessageCreated(String channelId) {
    unawaited(_resolveAndScheduleSession(channelId));
  }

  Future<void> _resolveAndScheduleSession(String channelId) async {
    try {
      final ch = await LocalDatabaseService().getChannelById(channelId);
      final agentId = ch?.members
              .where((m) => m.type == 'agent')
              .map((m) => m.id)
              .firstOrNull ??
          channelId;
      final ownerId = RuntimePaths.resolveOwnerId(
        agentId: agentId,
        channelId: channelId,
        channelType: ch?.type,
        parentGroupId: ch?.parentGroupId,
      );
      scheduleSessionMirror(ownerId: ownerId, channelId: channelId);
    } catch (e) {
      scheduleSessionMirror(ownerId: channelId, channelId: channelId);
    }
  }

  /// 消息落库后调用：debounce 刷新该 channel 的 session.json。
  void scheduleSessionMirror({
    required String ownerId,
    required String channelId,
  }) {
    final key = '$ownerId::$channelId';
    _pendingSession[key]?.cancel();
    _pendingSession[key] = Timer(debounce, () {
      _pendingSession.remove(key);
      unawaited(_mirrorSession(ownerId: ownerId, channelId: channelId));
    });
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

  Future<void> ensureRuntimeScaffold(String ownerId) async {
    final deviceId = await DeviceIdentity.deviceId();
    final now = DateTime.now().toUtc().toIso8601String();
    await _writeTextIfAbsent(
      deviceId,
      RuntimePaths.soulMd(ownerId),
      '<!-- mirrored soul; authoritative store is SQLite/minds -->\n',
    );
    await _writeTextIfAbsent(
      deviceId,
      RuntimePaths.memoryMd(ownerId),
      '<!-- mirrored memory; authoritative store is SQLite -->\n',
    );
    await _writeTextIfAbsent(
      deviceId,
      RuntimePaths.workspaceMd(ownerId),
      '# Workspace bindings\n\nworkspace_ids: []\n',
    );
    await _writeText(
      deviceId,
      RuntimePaths.contextManifest(ownerId),
      const JsonEncoder.withIndent('  ').convert({
        'schema_version': 1,
        'owner_id': ownerId,
        'source_device': deviceId,
        'updated_at': now,
        'soul_uri': RuntimePaths.uri(
            deviceId: deviceId, relPath: RuntimePaths.soulMd(ownerId)),
        'memory_uri': RuntimePaths.uri(
            deviceId: deviceId, relPath: RuntimePaths.memoryMd(ownerId)),
        'workspace_refs': <String>[],
        'channels': <String, dynamic>{},
      }),
    );
  }

  Future<void> _mirrorSession({
    required String ownerId,
    required String channelId,
  }) async {
    try {
      await ensureRuntimeScaffold(ownerId);
      final deviceId = await DeviceIdentity.deviceId();
      final rows = await LocalDatabaseService()
          .getChannelMessages(channelId, limit: 500, offset: 0);
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
          if (meta?['store_uri'] != null) 'store_uri': meta!['store_uri'],
        });
      }
      final payload = {
        'meta': {
          'channel_id': channelId,
          'owner_id': ownerId,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'schema_version': 1,
          'source_device': deviceId,
        },
        'messages': messages,
      };
      await _writeText(
        deviceId,
        RuntimePaths.sessionJson(ownerId, channelId),
        const JsonEncoder.withIndent('  ').convert(payload),
      );
      await _touchManifestChannel(deviceId, ownerId, channelId);
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

  Future<void> _touchManifestChannel(
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
      final (bytes, _, _) = await store.read(deviceId, StoreSpace.runtime, rel, 0, 1 << 20);
      manifest = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {}
    final channels = Map<String, dynamic>.from(
        (manifest['channels'] as Map?)?.cast<String, dynamic>() ?? {});
    channels[channelId] = {
      'session_uri': RuntimePaths.uri(
        deviceId: deviceId,
        relPath: RuntimePaths.sessionJson(ownerId, channelId),
      ),
    };
    manifest['channels'] = channels;
    manifest['updated_at'] = DateTime.now().toUtc().toIso8601String();
    manifest['soul_uri'] = RuntimePaths.uri(
        deviceId: deviceId, relPath: RuntimePaths.soulMd(ownerId));
    manifest['memory_uri'] = RuntimePaths.uri(
        deviceId: deviceId, relPath: RuntimePaths.memoryMd(ownerId));
    await _writeText(
      deviceId,
      rel,
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
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
