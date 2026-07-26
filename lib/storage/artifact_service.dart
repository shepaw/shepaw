import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'remote_read_service.dart';
import 'store_protocol.dart';
import 'store_service.dart';

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

    // 统一写入路径：经 store.* 写自己设备目录（loopback）
    final begin = await StoreService.instance.call(StoreFrame(
        op: StoreOp.writeBegin,
        payload: {
          'space': StoreSpace.artifacts,
          'path': relPath,
          'size': content.length,
          'sha256': hash,
        }));
    if (begin == null || begin.containsKey('_error')) {
      throw StateError('write.begin failed: ${begin?['_error']}');
    }
    final uploadId = begin['upload_id'] as String;
    var offset = begin['received'] as int? ?? 0;
    while (offset < content.length) {
      final end = (offset + LocalStore.maxReadChunk) > content.length
          ? content.length
          : offset + LocalStore.maxReadChunk;
      final chunk = await StoreService.instance.call(StoreFrame(
          op: StoreOp.writeChunk,
          payload: {
            'space': StoreSpace.artifacts,
            'upload_id': uploadId,
            'offset': offset,
            'data': base64Encode(content.sublist(offset, end)),
          }));
      if (chunk == null || chunk.containsKey('_error')) {
        throw StateError('write.chunk failed: ${chunk?['_error']}');
      }
      offset = chunk['received'] as int? ?? end;
    }
    final commit = await StoreService.instance.call(StoreFrame(
        op: StoreOp.commit,
        payload: {
          'space': StoreSpace.artifacts,
          'upload_ids': [uploadId],
        }));
    if (commit == null || commit.containsKey('_error')) {
      throw StateError('commit failed: ${commit?['_error']}');
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
  Future<Uint8List> readArtifact(String uriString) async {
    final uri = ArtifactUri.tryParse(uriString);
    if (uri == null) {
      throw ArgumentError('invalid artifact uri: $uriString');
    }
    final self = await DeviceIdentity.deviceId();
    if (uri.deviceId == self) {
      // 本机直读
      final store = await StoreService.instance.localStore();
      final builder = BytesBuilder(copy: false);
      var offset = 0;
      while (true) {
        final (chunk, _, eof) = await store.read(
            self, StoreSpace.artifacts, uri.storePath, offset,
            LocalStore.maxReadChunk);
        builder.add(chunk);
        offset += chunk.length;
        if (eof || chunk.isEmpty) break;
      }
      return builder.toBytes();
    }
    // 他端：经 master 缓存校验拉取（§7）
    final masterId = await StoreService.instance.masterDeviceId();
    final result = await RemoteReadService.instance.readVerified(
      serverDeviceId: masterId,
      deviceId: uri.deviceId,
      space: StoreSpace.artifacts,
      path: uri.storePath,
    );
    return result.bytes;
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
    buffer.writeln('读取：store_read 原样传入括号内 URI；'
        '产出：store_write 返回新 URI 即完成共享。');
    return buffer.toString();
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
