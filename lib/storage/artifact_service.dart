import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'runtime_paths.dart';
import 'store_protocol.dart';
import 'store_service.dart';
import 'store_uri_reader.dart';

/// 产物 URI：
/// - 新：`store://runtime/<device>/<owner>/<channel>/artifacts/<task>/<file>`
/// - legacy：`store://artifacts/<device>/<task>/<file>`
class ArtifactUri {
  ArtifactUri({
    required this.deviceId,
    required this.taskId,
    required this.filename,
    this.ownerId,
    this.channelId,
    this.space = StoreSpace.runtime,
  });

  final String deviceId;
  final String taskId;
  final String filename;
  final String? ownerId;
  final String? channelId;
  final String space;

  static const scheme = 'store';

  bool get isLegacy => space == StoreSpace.artifacts;

  /// 解析；非法返回 null。兼容 legacy artifacts 与 runtime 路径。
  static ArtifactUri? tryParse(String uri) {
    if (!uri.startsWith('$scheme://')) return null;
    final rest = uri.substring(scheme.length + 3);
    final segments = rest.split('/');
    if (segments.length < 3) return null;
    final space = segments[0];
    if (!isValidDeviceId(segments[1])) return null;

    String decode(String s) {
      try {
        return Uri.decodeComponent(s);
      } catch (_) {
        return s;
      }
    }

    if (space == StoreSpace.artifacts) {
      if (segments.length < 3) return null;
      final filename = segments.sublist(3).map(decode).join('/');
      if (filename.isEmpty || filename.contains('..')) return null;
      return ArtifactUri(
        deviceId: segments[1],
        taskId: decode(segments[2]),
        filename: filename,
        space: StoreSpace.artifacts,
      );
    }

    if (space == StoreSpace.runtime) {
      // runtime/<device>/<owner>/<channel>/artifacts/<task>/<file...>
      if (segments.length < 7) return null;
      if (segments[4] != 'artifacts') return null;
      final filename = segments.sublist(6).map(decode).join('/');
      if (filename.isEmpty || filename.contains('..')) return null;
      return ArtifactUri(
        deviceId: segments[1],
        ownerId: decode(segments[2]),
        channelId: decode(segments[3]),
        taskId: decode(segments[5]),
        filename: filename,
        space: StoreSpace.runtime,
      );
    }
    return null;
  }

  String get storePath {
    if (isLegacy) return '$taskId/$filename';
    return RuntimePaths.artifactFile(
      ownerId: ownerId ?? 'default',
      channelId: channelId ?? taskId,
      taskId: taskId,
      filename: filename,
    );
  }

  @override
  String toString() {
    if (isLegacy) {
      return '$scheme://artifacts/$deviceId/$taskId/$filename';
    }
    return '$scheme://runtime/$deviceId/${ownerId ?? 'default'}/'
        '${channelId ?? taskId}/artifacts/$taskId/$filename';
  }
}

/// 从文本中提取的产物引用（Markdown 链接 + 单行描述）。
class ArtifactReference {
  ArtifactReference({
    required this.uri,
    required this.linkText,
    this.description = '',
  });

  final ArtifactUri uri;
  final String linkText;
  final String description;

  String toMarkdownLine() {
    final base = formatStoreMarkdownLink(linkText, uri.toString());
    return description.isEmpty ? base : '$base — $description';
  }
}

/// 产物服务：新写入落 runtime；legacy URI 仍可读。
class ArtifactService {
  ArtifactService._();
  static final ArtifactService instance = ArtifactService._();

  static const _tag = 'Artifact';
  final _log = LoggerService();

  static final _referencePattern = RegExp(
      r'\[([^\]]+)\]\((store://(?:artifacts|runtime)/[0-9a-f]{16}/[^)]+)\)(?:\s*—\s*([^\n]+))?');

  /// 写入产物并返回单行 Markdown 引用。
  ///
  /// [runtimeOwnerId] / [channelId] 缺省时分别回退到 `default` / [taskId]
  /// （CLI 应始终注入真实 agent/channel，避免落到 default/general）。
  Future<String> writeArtifact({
    required String taskId,
    required String filename,
    required Uint8List content,
    String? description,
    String? producer,
    String? runtimeOwnerId,
    String? channelId,
  }) async {
    final deviceId = await DeviceIdentity.deviceId();
    final safeName = p.basename(filename);
    final owner = RuntimePaths.sanitizeSegment(
      (runtimeOwnerId != null && runtimeOwnerId.trim().isNotEmpty)
          ? runtimeOwnerId
          : 'default',
    );
    final channel = RuntimePaths.sanitizeSegment(
      (channelId != null && channelId.trim().isNotEmpty)
          ? channelId
          : ((runtimeOwnerId != null && runtimeOwnerId.trim().isNotEmpty)
              ? runtimeOwnerId
              : taskId),
    );
    final uri = ArtifactUri(
      deviceId: deviceId,
      taskId: RuntimePaths.sanitizeSegment(taskId),
      filename: safeName,
      ownerId: owner,
      channelId: channel,
      space: StoreSpace.runtime,
    );
    final relPath = uri.storePath;
    final hash = crypto.sha256.convert(content).toString();

    final store = await StoreService.instance.localStore();
    final (uploadId, _) = await store.writeBegin(
      deviceId: deviceId,
      space: StoreSpace.runtime,
      path: relPath,
      size: content.length,
      sha256: hash,
    );
    var offset = 0;
    while (offset < content.length) {
      final end = (offset + LocalStore.maxReadChunk) > content.length
          ? content.length
          : offset + LocalStore.maxReadChunk;
      await store.writeChunk(deviceId, StoreSpace.runtime, uploadId, offset,
          content.sublist(offset, end));
      offset = end;
    }
    final (committed, failed) =
        await store.commit(deviceId, StoreSpace.runtime, [uploadId]);
    if (failed.isNotEmpty || committed.isEmpty) {
      throw StateError('artifact commit failed: $failed');
    }
    _log.info('artifact written: $uri (${content.length} bytes)', tag: _tag);

    return ArtifactReference(
      uri: uri,
      linkText: safeName,
      description: _buildDescription(
          description: description, content: content, producer: producer),
    ).toMarkdownLine();
  }

  /// 读取产物（legacy artifacts 与 runtime 均可）。
  Future<Uint8List> readArtifact(String uriString) async {
    final uri = ArtifactUri.tryParse(uriString);
    if (uri == null) {
      throw ArgumentError('invalid artifact uri: $uriString');
    }
    return StoreUriReader.instance.read(uriString);
  }

  List<ArtifactReference> parseReferences(String text) {
    final refs = <ArtifactReference>[];
    for (final match in _referencePattern.allMatches(text)) {
      final uri = ArtifactUri.tryParse(match.group(2)!);
      if (uri == null) continue;
      refs.add(ArtifactReference(
        uri: uri,
        linkText: match.group(1)!,
        description: match.group(3)?.trim() ?? '',
      ));
    }
    return refs;
  }

  /// 组装"## 可用产物"工作流注入片段（§6.3 编排层注入）。
  String buildAvailableArtifactsSection(List<ArtifactReference> refs) {
    if (refs.isEmpty) return '';
    final buffer = StringBuffer('## 可用产物\n');
    for (final ref in refs) {
      buffer.writeln('- ${ref.toMarkdownLine()}');
    }
    buffer.writeln('新产出优先 `shepaw store write`（勿默认写 OS 路径）；'
        '读 `store://` 遵循消息内 `[implicit]` 提示（`shepaw store read`）。');
    return buffer.toString();
  }

  /// 从 [text] 提取产物引用行，去重合并进 [target]（工作流跨步骤累积用）。
  void mergeReferenceLines(List<String> target, String text) {
    for (final ref in parseReferences(text)) {
      final line = ref.toMarkdownLine();
      if (!target.contains(line)) target.add(line);
    }
  }

  /// 工作流步骤摘要：超长时优先保留末尾的 store:// 引用行。
  String truncateStepSummary(String output, {int maxLen = 500}) {
    if (output.length <= maxLen) return output;
    final refs = parseReferences(output);
    if (refs.isEmpty) {
      return '${output.substring(0, maxLen - 3)}...';
    }
    final suffix = refs.map((r) => r.toMarkdownLine()).join('\n');
    final suffixBlock = '\n$suffix';
    if (suffixBlock.length >= maxLen) {
      return suffixBlock.substring(0, maxLen);
    }
    final prefixLen = maxLen - suffixBlock.length;
    if (prefixLen <= 3) return suffixBlock.substring(0, maxLen);
    return '${output.substring(0, prefixLen - 3)}...$suffixBlock';
  }

  /// 编排层注入包装（§6.3）：解析 [text]（及 [extraRefTexts]）中的产物
  /// 引用，去重后以标准"## 可用产物"片段追加到任务上下文。
  /// 无引用时原文返回（不注水）。
  String wrapWithArtifactSection(String text,
      {List<String> extraRefTexts = const []}) {
    final byUri = <String, ArtifactReference>{};
    void collect(String t) {
      for (final ref in parseReferences(t)) {
        byUri.putIfAbsent(ref.uri.toString(), () => ref);
      }
    }

    collect(text);
    for (final extra in extraRefTexts) {
      collect(extra);
    }
    final refs = byUri.values.take(10).toList();
    if (refs.isEmpty) return text;
    return '$text\n\n${buildAvailableArtifactsSection(refs)}';
  }

  String _buildDescription(
      {String? description, Uint8List? content, String? producer}) {
    final size = _fmtBytes(content?.length ?? 0);
    final parts = <String>[
      if (description != null && description.isNotEmpty) description,
      size,
      if (producer != null && producer.isNotEmpty) '$producer 产出',
    ];
    return parts.join('，');
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)}KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
  }
}
