import 'dart:convert';
import 'dart:typed_data';

import '../../cli_base.dart';
import '../../../storage/artifact_service.dart';

/// [TOOLING 层] store 命名空间 - 存储空间产物读写
///
/// 对应 docs/storage_space_plan.md §6.3 的 Agent 侧纪律：
/// - `store_write`（`write`）：产出写入自己设备目录，返回新 URI 即完成共享；
/// - `store_read`（`read`）：单参数 URI 读取产物，分块/缓存由工具层处理。
///
/// Agent 只"转述"URI，不构造 URI（URI 从本命令输出或用户/上游输入获得）。
class StoreNamespace extends CliNamespace {
  static final instance = StoreNamespace._();
  StoreNamespace._();

  @override
  String get namespace => 'store';

  @override
  String get description =>
      'Artifact store: write artifacts (share via URI) and read them back';

  @override
  Map<String, CliCommand> get commands => {
        'write': StoreWriteCommand(),
        'read': StoreReadCommand(),
      };
}

/// `shepaw store write --filename <name> --content <text> [--task <id>] [--desc <text>]`
class StoreWriteCommand extends CliCommand {
  @override
  String get name => 'write';

  @override
  String get description =>
      'Write an artifact and get back a shareable store:// URI reference';

  @override
  String get usage =>
      'shepaw store write --filename report.md --content "# Q2 report" '
      '--task task-41 --desc "Q2 销售报告"';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final filename = flags['filename'] ?? flags['name'];
    if (filename == null || filename.isEmpty) {
      return {'success': false, 'error': 'missing --filename'};
    }
    final contentText = flags['content'] ?? '';
    if (contentText.isEmpty) {
      return {'success': false, 'error': 'missing --content'};
    }
    final taskId = flags['task'] ?? 'general';
    final desc = flags['desc'];
    try {
      final reference = await ArtifactService.instance.writeArtifact(
        taskId: taskId,
        filename: filename,
        content: Uint8List.fromList(utf8.encode(contentText)),
        description: desc,
        producer: flags['producer'],
      );
      final uri = ArtifactService.instance
          .parseReferences(reference)
          .single
          .uri
          .toString();
      return {
        'success': true,
        'uri': uri,
        'reference': reference,
        'note': '返回即完成共享（本地优先，后台同步）。引用时原样使用 reference 单行。',
      };
    } catch (e) {
      return {'success': false, 'error': '$e'};
    }
  }
}

/// `shepaw store read --uri <store://...>`
class StoreReadCommand extends CliCommand {
  @override
  String get name => 'read';

  @override
  String get description =>
      'Read an artifact by its store:// URI (cache-validated)';

  @override
  String get usage =>
      'shepaw store read --uri store://artifacts/0123456789abcdef/task-41/report.md';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final uri = flags['uri'];
    if (uri == null || uri.isEmpty) {
      return {'success': false, 'error': 'missing --uri'};
    }
    try {
      final bytes = await ArtifactService.instance.readArtifact(uri);
      // 文本优先直接返回；二进制给 base64
      String? text;
      try {
        text = utf8.decode(bytes);
      } catch (_) {}
      return <String, dynamic>{
        'success': true,
        'size': bytes.length,
        if (text != null) 'content': text else 'content_base64': base64Encode(bytes),
        if (text == null) 'encoding': 'base64',
      };
    } catch (e) {
      return {'success': false, 'error': '$e'};
    }
  }
}
