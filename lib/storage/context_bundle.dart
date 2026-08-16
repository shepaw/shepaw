import 'dart:convert';

import '../services/logger_service.dart';
import 'artifact_service.dart';
import 'device_identity.dart';
import 'runtime_paths.dart';
import 'scope_card.dart';
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

  /// 注入用的 store://（默认 omitPersona：群不收个人 cognition）。
  List<String> collectUris({
    String? preferChannelId,
    bool omitPersona = false,
  }) {
    final out = <String>{};
    if (!omitPersona) {
      if (soulUri != null && soulUri!.isNotEmpty) out.add(soulUri!);
      if (memoryUri != null && memoryUri!.isNotEmpty) out.add(memoryUri!);
    }
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

/// 读写 ContextBundle，并生成多 agent 注入片段（Scope Card）。
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

  /// 组装本轮 Scope Card（volatile 为主；含 manifest / runtime 根）。
  ///
  /// 稳定说明书应已在 system prompt；此处避免再贴完整 stable，只给本轮 URI。
  /// 若调用方需要单段完整卡（无 system 卡时），设 [includeStable]=true。
  Future<ScopeCard> buildLocalScopeCard({
    required String ownerId,
    String? channelId,
    bool expandUris = false,
    bool isGroup = false,
  }) async {
    final deviceId = await DeviceIdentity.deviceId();
    final extras = <String>[];
    if (expandUris) {
      final bundle = await loadLocal(ownerId);
      if (bundle != null) {
        extras.addAll(bundle.collectUris(
          preferChannelId: channelId,
          omitPersona: isGroup,
        ));
      }
    }
    if (isGroup) {
      return ScopeCard.forGroup(
        groupId: ownerId,
        deviceId: deviceId,
        channelId: channelId,
        extraUris: ScopeCard.dedupeUris(extras),
      );
    }
    return ScopeCard.forAgentDm(
      agentId: ownerId,
      deviceId: deviceId,
      channelId: channelId,
    ).copyWith(extraUris: ScopeCard.dedupeUris(extras));
  }

  /// @Deprecated 兼容旧测试名；返回 volatile（或完整）Markdown。
  Future<String> buildLocalContextSection({
    required String ownerId,
    String? channelId,
    bool expandUris = false,
    bool isGroup = false,
    bool includeStable = false,
  }) async {
    final card = await buildLocalScopeCard(
      ownerId: ownerId,
      channelId: channelId,
      expandUris: expandUris,
      isGroup: isGroup,
    );
    if (includeStable) return card.toMarkdown();
    final vol = card.toVolatileMarkdown();
    if (vol.isNotEmpty) return vol;
    // 无 URI 时仍给短提示，避免空白
    return includeStable
        ? card.toStableMarkdown()
        : '${card.toStableMarkdown()}\n\n'
            '（本轮暂无额外 URI；可 list runtime 根）';
  }

  /// 在任务文本后追加产物引用 + Scope Card 本轮段。
  Future<String> wrapWithContextBundle(
    String text, {
    required String ownerId,
    String? channelId,
    List<String> extraRefTexts = const [],
    List<String> extraUris = const [],
    bool expandUris = false,
    bool isGroup = false,
  }) async {
    final withArts = ArtifactService.instance
        .wrapWithArtifactSection(text, extraRefTexts: extraRefTexts);
    try {
      final card = await buildLocalScopeCard(
        ownerId: ownerId,
        channelId: channelId,
        expandUris: expandUris,
        isGroup: isGroup,
      );
      final merged = card.copyWith(
        extraUris: ScopeCard.dedupeUris([...card.extraUris, ...extraUris]),
      );
      final section = merged.toVolatileMarkdown();
      if (section.isEmpty) return withArts;
      if (withArts.contains('## 当前储物袋作用域')) return withArts;
      if (withArts.contains('## 可用上下文')) return withArts;
      return '$withArts\n\n$section';
    } catch (e) {
      _log.warning('wrapWithContextBundle failed: $e', tag: _tag);
      return withArts;
    }
  }
}
