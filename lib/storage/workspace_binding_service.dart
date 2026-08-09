import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'memory_paths.dart';
import 'runtime_mirror_service.dart';
import 'runtime_paths.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// 读写 `runtime/<owner>/workspace.md`，并同步 ContextBundle `workspace_refs`。
class WorkspaceBindingService {
  WorkspaceBindingService._();
  static final WorkspaceBindingService instance = WorkspaceBindingService._();

  static const _tag = 'WorkspaceBind';
  final _log = LoggerService();

  /// 列出本机 workspaces 根下的 workspace_id（目录名）。
  Future<List<String>> listAvailableWorkspaceIds() async {
    final deviceId = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    final entries = await store.list(
      deviceId,
      StoreSpace.workspaces,
      depth: 1,
      limit: 500,
    );
    final ids = <String>[
      for (final e in entries)
        if (e.isDir) e.path.split('/').first,
    ];
    ids.sort();
    return ids;
  }

  /// 当前已绑定的 workspace_id 列表。
  Future<List<String>> loadBoundIds(String ownerId) async {
    await RuntimeMirrorService.instance.ensureRuntimeScaffold(ownerId);
    final deviceId = await DeviceIdentity.deviceId();
    final text = await _readRuntimeText(
      deviceId,
      RuntimePaths.workspaceMd(ownerId),
    );
    return parseWorkspaceIds(text ?? '');
  }

  /// 解析 `workspace_ids: [a, b]` 或 YAML 风格列表。
  static List<String> parseWorkspaceIds(String md) {
    final ids = <String>[];
    final inline = RegExp(r'workspace_ids\s*:\s*\[([^\]]*)\]');
    final m = inline.firstMatch(md);
    if (m != null) {
      for (final part in m.group(1)!.split(',')) {
        final id = part.trim().replaceAll(RegExp(r'''^["']|["']$'''), '');
        if (id.isNotEmpty) ids.add(id);
      }
      return ids;
    }
    // Fallback: lines under workspace_ids:
    var inList = false;
    for (final line in md.split('\n')) {
      final t = line.trim();
      if (t.startsWith('workspace_ids:')) {
        inList = true;
        continue;
      }
      if (inList) {
        if (t.startsWith('- ')) {
          final id = t.substring(2).trim();
          if (id.isNotEmpty) ids.add(id);
        } else if (t.isNotEmpty && !t.startsWith('#')) {
          break;
        }
      }
    }
    return ids;
  }

  Future<void> saveBoundIds(String ownerId, List<String> workspaceIds) async {
    final unique = workspaceIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList()
      ..sort();
    final deviceId = await DeviceIdentity.deviceId();
    await RuntimeMirrorService.instance.ensureRuntimeScaffold(ownerId);
    final md = StringBuffer()
      ..writeln('# Workspace bindings')
      ..writeln()
      ..writeln(
          'workspace_ids: [${unique.map((e) => '"$e"').join(', ')}]')
      ..writeln()
      ..writeln('<!-- updated_at: ${DateTime.now().toUtc().toIso8601String()} -->');
    await _writeRuntimeText(
      deviceId,
      RuntimePaths.workspaceMd(ownerId),
      md.toString(),
    );
    await _syncManifestWorkspaceRefs(ownerId, deviceId, unique);
    _log.info(
      'bound ${unique.length} workspaces for $ownerId',
      tag: _tag,
    );
  }

  Future<void> _syncManifestWorkspaceRefs(
    String ownerId,
    String deviceId,
    List<String> workspaceIds,
  ) async {
    final rel = RuntimePaths.contextManifest(ownerId);
    Map<String, dynamic> manifest = {
      'schema_version': 1,
      'owner_id': ownerId,
      'source_device': deviceId,
      'channels': <String, dynamic>{},
    };
    try {
      final text = await _readRuntimeText(deviceId, rel);
      if (text != null && text.isNotEmpty) {
        manifest = jsonDecode(text) as Map<String, dynamic>;
      }
    } catch (_) {}
    manifest['workspace_refs'] = [
      for (final id in workspaceIds)
        storeUriWithRef(StoreSpace.workspaces, deviceId, id),
    ];
    manifest['soul_uri'] = MemoryPaths.uri(
      deviceId: deviceId,
      relPath: MemoryPaths.soulMd(ownerId),
    );
    manifest['memory_uri'] = MemoryPaths.uri(
      deviceId: deviceId,
      relPath: MemoryPaths.entriesDir(ownerId),
    );
    manifest['updated_at'] = DateTime.now().toUtc().toIso8601String();
    await _writeRuntimeText(
      deviceId,
      rel,
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
  }

  Future<String?> _readRuntimeText(String deviceId, String relPath) async {
    try {
      final store = await StoreService.instance.localStore();
      final buf = BytesBuilder(copy: false);
      var offset = 0;
      while (true) {
        final (chunk, size, eof) = await store.read(
          deviceId,
          StoreSpace.runtime,
          relPath,
          offset,
          LocalStore.maxReadChunk,
        );
        if (chunk.isNotEmpty) buf.add(chunk);
        offset += chunk.length;
        if (eof || offset >= size) break;
      }
      final bytes = buf.takeBytes();
      if (bytes.isEmpty) return null;
      return utf8.decode(bytes);
    } on StoreException catch (e) {
      if (e.code == StoreError.notFound) return null;
      rethrow;
    }
  }

  Future<void> _writeRuntimeText(
    String deviceId,
    String relPath,
    String text,
  ) async {
    final content = Uint8List.fromList(utf8.encode(text));
    final hash = crypto.sha256.convert(content).toString();
    final store = await StoreService.instance.localStore();
    final path = normalizeStorePath(relPath);
    final (uploadId, _) = await store.writeBegin(
      deviceId: deviceId,
      space: StoreSpace.runtime,
      path: path,
      size: content.length,
      sha256: hash,
    );
    var offset = 0;
    while (offset < content.length) {
      final end = (offset + LocalStore.maxReadChunk) > content.length
          ? content.length
          : offset + LocalStore.maxReadChunk;
      await store.writeChunk(
        deviceId,
        StoreSpace.runtime,
        uploadId,
        offset,
        content.sublist(offset, end),
      );
      offset = end;
    }
    final (ok, failed) =
        await store.commit(deviceId, StoreSpace.runtime, [uploadId]);
    if (failed.isNotEmpty || ok.isEmpty) {
      throw StateError('workspace.md write failed: $failed');
    }
  }
}
