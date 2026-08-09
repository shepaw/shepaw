import 'dart:convert';

import '../services/logger_service.dart';
import 'artifact_service.dart';
import 'device_identity.dart';
import 'runtime_paths.dart';
import 'store_uri_reader.dart';

/// ContextBundle：runtime 上下文清单（docs/CLIENT_PROFILES.md）。
///
/// 物理文件：`runtime/<owner>/context.manifest.json`。
/// App 聊天仍以 SQLite 为准；本包只用于分享 / 跨设备 / 多 agent 注入。
class ContextBundle {
  ContextBundle({
    required this.ownerId,
    required this.sourceDevice,
    required this.updatedAt,
    this.soulUri,
    this.memoryUri,
    this.workspaceRefs = const [],
    this.channels = const {},
    this.schemaVersion = 1,
  });

  final int schemaVersion;
  final String ownerId;
  final String sourceDevice;
  final String updatedAt;
  final String? soulUri;
  final String? memoryUri;
  final List<String> workspaceRefs;
  final Map<String, String> channels; // channelId → session_uri

  factory ContextBundle.fromJson(Map<String, dynamic> json) {
    final channelsRaw = json['channels'];
    final channels = <String, String>{};
    if (channelsRaw is Map) {
      for (final e in channelsRaw.entries) {
        final v = e.value;
        if (v is Map && v['session_uri'] is String) {
          channels['${e.key}'] = v['session_uri'] as String;
        } else if (v is String) {
          channels['${e.key}'] = v;
        }
      }
    }
    return ContextBundle(
      schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 1,
      ownerId: json['owner_id'] as String? ?? '',
      sourceDevice: json['source_device'] as String? ?? '',
      updatedAt: json['updated_at'] as String? ?? '',
      soulUri: json['soul_uri'] as String?,
      memoryUri: json['memory_uri'] as String?,
      workspaceRefs:
          (json['workspace_refs'] as List?)?.cast<String>() ?? const [],
      channels: channels,
    );
  }

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'owner_id': ownerId,
        'source_device': sourceDevice,
        'updated_at': updatedAt,
        if (soulUri != null) 'soul_uri': soulUri,
        if (memoryUri != null) 'memory_uri': memoryUri,
        'workspace_refs': workspaceRefs,
        'channels': {
          for (final e in channels.entries)
            e.key: {'session_uri': e.value},
        },
      };

  /// 注入用的全部 store://（soul/memory/session/workspace）。
  List<String> collectUris({String? preferChannelId}) {
    final out = <String>{};
    if (soulUri != null && soulUri!.isNotEmpty) out.add(soulUri!);
    if (memoryUri != null && memoryUri!.isNotEmpty) out.add(memoryUri!);
    for (final w in workspaceRefs) {
      if (w.startsWith('store://')) out.add(w);
    }
    if (preferChannelId != null && channels.containsKey(preferChannelId)) {
      out.add(channels[preferChannelId]!);
    } else {
      out.addAll(channels.values);
    }
    return out.toList()..sort();
  }
}

/// 读写 ContextBundle，并生成多 agent 注入片段。
class ContextBundleService {
  ContextBundleService._();
  static final ContextBundleService instance = ContextBundleService._();

  static const _tag = 'ContextBundle';
  final _log = LoggerService();

  /// 读取本机 owner 的 manifest；不存在返回 null。
  Future<ContextBundle?> loadLocal(String ownerId) async {
    try {
      final deviceId = await DeviceIdentity.deviceId();
      final uri = RuntimePaths.uri(
        deviceId: deviceId,
        relPath: RuntimePaths.contextManifest(ownerId),
      );
      final bytes = await StoreUriReader.instance.read(uri);
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      return ContextBundle.fromJson(json);
    } catch (e) {
      _log.debug('loadLocal miss owner=$ownerId: $e', tag: _tag);
      return null;
    }
  }

  /// 经 store URI 读取（可跨设备）。
  Future<ContextBundle?> loadUri(String manifestUri) async {
    try {
      final bytes = await StoreUriReader.instance.read(manifestUri);
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      return ContextBundle.fromJson(json);
    } catch (e) {
      _log.warning('loadUri failed $manifestUri: $e', tag: _tag);
      return null;
    }
  }

  /// 组装 `## 可用上下文` 注入块（URI 列表，不贴全文）。
  String buildContextSection({
    required String ownerId,
    String? channelId,
    required List<String> uris,
  }) {
    final unique = uris.where((u) => u.isNotEmpty).toSet().toList()..sort();
    final buf = StringBuffer('## 可用上下文（ContextBundle）\n');
    buf.writeln('owner: `$ownerId`');
    if (channelId != null && channelId.isNotEmpty) {
      buf.writeln('channel: `$channelId`');
    }
    buf.writeln(
        '先 `shepaw store read` 拉取 **context.manifest.json**，再按需读取其中的 soul/memory/session/workspace URI；勿假设已内嵌全文。');
    if (unique.isEmpty) {
      buf.writeln('- （暂无 URI；可先 list `runtime/$ownerId/`）');
    } else {
      for (final u in unique) {
        buf.writeln('- `$u`');
      }
    }
    return buf.toString();
  }

  /// 读取本机 bundle 并生成注入段。
  ///
  /// 默认只注入 **manifest URI**（瘦身）；[expandUris]=true 时附带 collectUris。
  Future<String> buildLocalContextSection({
    required String ownerId,
    String? channelId,
    bool expandUris = false,
  }) async {
    final deviceId = await DeviceIdentity.deviceId();
    final manifestUri = RuntimePaths.uri(
      deviceId: deviceId,
      relPath: RuntimePaths.contextManifest(ownerId),
    );
    final uris = <String>[manifestUri];
    if (expandUris) {
      final bundle = await loadLocal(ownerId);
      if (bundle != null) {
        uris.addAll(bundle.collectUris(preferChannelId: channelId));
      }
    }
    return buildContextSection(
      ownerId: ownerId,
      channelId: channelId,
      uris: uris,
    );
  }

  /// 在任务文本后追加产物引用 + ContextBundle（默认只挂 manifest URI）。
  Future<String> wrapWithContextBundle(
    String text, {
    required String ownerId,
    String? channelId,
    List<String> extraRefTexts = const [],
    bool expandUris = false,
  }) async {
    final withArts = ArtifactService.instance
        .wrapWithArtifactSection(text, extraRefTexts: extraRefTexts);
    try {
      final section = await buildLocalContextSection(
        ownerId: ownerId,
        channelId: channelId,
        expandUris: expandUris,
      );
      if (withArts.contains('## 可用上下文')) return withArts;
      return '$withArts\n\n$section';
    } catch (e) {
      _log.warning('wrapWithContextBundle failed: $e', tag: _tag);
      return withArts;
    }
  }
}
