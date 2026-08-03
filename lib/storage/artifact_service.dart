import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'store_protocol.dart';
import 'store_service.dart';
import 'store_uri_reader.dart';

/// 产物 URI（docs/storage_space_plan.md §6.3）：
/// `store://artifacts/<device_id>/<task_id>/<filename>`。
/// URI 与具体 master 解耦，由本服务解析（本机直读 / master 缓存校验拉取）。
class ArtifactUri {
  ArtifactUri({
    required this.deviceId,
    required this.taskId,
    required this.filename,
  });

  final String deviceId;
  final String taskId;
  final String filename;

  static const scheme = 'store';

  /// 解析；非法返回 null。
  static ArtifactUri? tryParse(String uri) {
    if (!uri.startsWith('$scheme://')) return null;
    final rest = uri.substring(scheme.length + 3);
    final segments = rest.split('/');
    if (segments.length < 3) return null;
    if (segments[0] != 'artifacts') return null;
    if (!isValidDeviceId(segments[1])) return null;
    final filename = segments.sublist(3).join('/');
    if (filename.isEmpty || filename.contains('..')) return null;
    return ArtifactUri(
      deviceId: segments[1],
      taskId: segments[2],
      filename: filename,
    );
  }

  /// store 内的相对路径（<space>/<task>/<filename>）。
  String get storePath => '$taskId/$filename';

  @override
  String toString() =>
      '$scheme://artifacts/$deviceId/$taskId/$filename';
}

/// 从文本中提取的产物引用（Markdown 链接 + 单行描述，§6.3）。
class ArtifactReference {
  ArtifactReference({
    required this.uri,
    required this.linkText,
    this.description = '',
  });

  final ArtifactUri uri;
  final String linkText;
  final String description;

  /// 单行引用格式（Agent 间传递的唯一格式）。
  String toMarkdownLine() {
    final base = '[$linkText]($uri)';
    return description.isEmpty ? base : '$base — $description';
  }
}

/// 产物服务（§6.3）。
///
/// - 写入：任何端的 Agent（含 master 本机）产出统一经 store.* 写入
///   自己设备目录（无特权路径），返回即完成共享（本地优先，后台同步）。
/// - 读取：本机直读；他端经 RemoteReadService 缓存校验（hash 一致零
///   内容流量），分块/缓存/大文件由工具层处理。
/// - 引用：Agent 只"转述"URI，从不"构造"URI（改写/拼接路径由本服务完成）。
class ArtifactService {
  ArtifactService._();
  static final ArtifactService instance = ArtifactService._();

  static const _tag = 'Artifact';
  final _log = LoggerService();

  static final _referencePattern = RegExp(
      r'\[([^\]]+)\]\((store://artifacts/[0-9a-f]{16}/[^)]+)\)(?:\s*—\s*([^\n]+))?');

  /// 写入产物并返回单行 Markdown 引用（§6.3 引用表达格式）。
  ///
  /// 本地优先：经 [LocalStore] 写入自己设备目录并入同步队列；
  /// [description] 一句话描述（可选）；[producer] 产出者名（如 agent 名）。
  Future<String> writeArtifact({
    required String taskId,
    required String filename,
    required Uint8List content,
    String? description,
    String? producer,
  }) async {
    final deviceId = await DeviceIdentity.deviceId();
    final safeName = p.basename(filename); // 防路径穿越
    final uri =
        ArtifactUri(deviceId: deviceId, taskId: taskId, filename: safeName);
    final relPath = uri.storePath;
    final hash = crypto.sha256.convert(content).toString();

    // 本地优先（与 AttachmentService 同路径）：正式区 + SyncJournal，后台镜像
    final store = await StoreService.instance.localStore();
    final (uploadId, _) = await store.writeBegin(
      deviceId: deviceId,
      space: StoreSpace.artifacts,
      path: relPath,
      size: content.length,
      sha256: hash,
    );
    var offset = 0;
    while (offset < content.length) {
      final end = (offset + LocalStore.maxReadChunk) > content.length
          ? content.length
          : offset + LocalStore.maxReadChunk;
      await store.writeChunk(deviceId, StoreSpace.artifacts, uploadId, offset,
          content.sublist(offset, end));
      offset = end;
    }
    final (committed, failed) =
        await store.commit(deviceId, StoreSpace.artifacts, [uploadId]);
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

  /// 读取产物（单参数 URI；缓存/分块由本层处理）。
  /// 本机直读；他端经缓存校验（可能 stale，调用方可用 bytes 内容 hash 复核）。
  ///
  /// 仅接受 `store://artifacts/...`；通用 `files` 等请用 [StoreUriReader.read]。
  Future<Uint8List> readArtifact(String uriString) async {
    final uri = ArtifactUri.tryParse(uriString);
    if (uri == null) {
      throw ArgumentError('invalid artifact uri: $uriString');
    }
    return StoreUriReader.instance.read(uriString);
  }

  /// 从文本提取全部产物引用（Agent 输出/用户消息）。
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
