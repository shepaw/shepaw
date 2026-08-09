import 'dart:convert';
import 'dart:typed_data';

import '../../cli_base.dart';
import '../chat/chat_agent_scope.dart';
import '../../../services/local_database_service.dart';
import '../../../storage/artifact_service.dart';
import '../../../storage/public_store_service.dart';
import '../../../storage/runtime_paths.dart';
import '../../../storage/store_protocol.dart';
import '../../../storage/store_service.dart';
import '../../../storage/store_uri_reader.dart';

/// [TOOLING 层] store 命名空间 - 存储空间产物/文件读写
///
/// 对应 docs/storage_space_plan.md §6.3 的 Agent 侧纪律：
/// - `store_write`（`write`）：产出写入自己设备目录，返回新 URI 即完成共享；
/// - `store_read`（`read`）：单参数 URI 读取（`artifacts` / `files` 等），分块/缓存由工具层处理；
/// - `store_list`（`list`）：默认 `--depth 1` 一层一层列目录（含 `kind:dir`），
///   便于跨 agent（`store://agents/<device>/<uuid>/`）遍历；`--depth 0` 才递归全量文件。
///
/// Agent 只"转述"URI，不构造 URI（URI 从本命令输出或用户/上游输入获得）。
/// 遇到 `store://...` 一律用本命名空间，不要用 OS `file_read`。
class StoreNamespace extends CliNamespace {
  static final instance = StoreNamespace._();
  StoreNamespace._();

  @override
  String get namespace => 'store';

  @override
  String get description =>
      'Store URIs (store://…): write artifacts, read files, list folders '
      '(prefer --depth 1 for agents/workspaces trees) — prefer over OS paths '
      'whenever you see a store:// link';

  @override
  Map<String, CliCommand> get commands => {
        'write': StoreWriteCommand(),
        'read': StoreReadCommand(),
        'list': StoreListCommand(),
      };
}

/// `shepaw store write --filename <name> --content <text> [--task <id>] [--desc <text>]`
/// 或 `… write --space public --filename <name> --content <text>`
///
/// 落点：`runtime/<owner>/<channel>/artifacts/<task>/<file>`。
/// [owner]/[channel] 优先取 flags，否则取 [ChatAgentScope]（由 ShepawCLI 注入）。
class StoreWriteCommand extends CliCommand {
  @override
  String get name => 'write';

  @override
  String get description =>
      'Preferred path for produced artifacts: write to store and get a shareable '
      'store:// URI (prefer this over os.file.write for reports/code/docs). '
      'Use --space public for the public partition.';

  @override
  String get usage =>
      'shepaw store write --filename report.md --content "# Q2 report" '
      '--task task-41 --desc "Q2 销售报告"\n'
      'shepaw store write --space public --filename note.md --content "hello"';

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
    final space = flags['space'] ?? '';
    if (space == StoreSpace.public_) {
      try {
        final uri = await PublicStoreService.instance.writeText(
          relPath: filename,
          content: contentText,
        );
        return {
          'success': true,
          'uri': uri,
          'space': StoreSpace.public_,
          'note': '已写入 public/；可用 store:// 引用。',
        };
      } catch (e) {
        return {'success': false, 'error': '$e'};
      }
    }
    final taskId = flags['task'] ?? 'general';
    final desc = flags['desc'];
    final agentId = (flags['agent_id'] ?? flags['owner'] ?? ChatAgentScope.agentId)
        .trim();
    final channelId =
        (flags['channel_id'] ?? flags['channel'] ?? ChatAgentScope.channelId)
            .trim();
    try {
      final ownerId = await _resolveRuntimeOwner(
        agentId: agentId.isNotEmpty ? agentId : ChatAgentScope.agentId,
        channelId: channelId.isNotEmpty ? channelId : null,
      );
      final effectiveChannel =
          channelId.isNotEmpty ? channelId : ownerId;
      final reference = await ArtifactService.instance.writeArtifact(
        taskId: taskId,
        filename: filename,
        content: Uint8List.fromList(utf8.encode(contentText)),
        description: desc,
        producer: flags['producer'] ?? agentId,
        runtimeOwnerId: ownerId,
        channelId: effectiveChannel,
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
        'owner_id': ownerId,
        'channel_id': effectiveChannel,
        'note': '返回即完成共享（本地优先，后台同步）。引用时原样使用 reference 单行。',
      };
    } catch (e) {
      return {'success': false, 'error': '$e'};
    }
  }

  /// 群聊用 group/parentGroupId；单聊用 agentId。
  Future<String> _resolveRuntimeOwner({
    required String agentId,
    String? channelId,
  }) async {
    if (channelId == null || channelId.isEmpty) {
      return RuntimePaths.sanitizeSegment(agentId);
    }
    try {
      final ch = await LocalDatabaseService().getChannelById(channelId);
      return RuntimePaths.resolveOwnerId(
        agentId: agentId,
        channelId: channelId,
        channelType: ch?.type,
        parentGroupId: ch?.parentGroupId,
      );
    } catch (_) {
      return RuntimePaths.sanitizeSegment(agentId);
    }
  }
}

/// `shepaw store read --uri <store://...>`
class StoreReadCommand extends CliCommand {
  @override
  String get name => 'read';

  @override
  String get description =>
      'Read a store:// URI (artifacts, files, or own-device private spaces; '
      'cache-validated). Use this for ANY store:// link — never os.file.read.';

  @override
  String get usage =>
      'shepaw store read --uri store://files/0123456789abcdef/docs/note.txt\n'
      'shepaw store read --uri store://artifacts/0123456789abcdef/task-41/report.md';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final uri = flags['uri'];
    if (uri == null || uri.isEmpty) {
      return {'success': false, 'error': 'missing --uri'};
    }
    try {
      final bytes = await StoreUriReader.instance.read(uri);
      // 文本优先直接返回；二进制给 base64
      String? text;
      try {
        text = utf8.decode(bytes);
      } catch (_) {}
      return <String, dynamic>{
        'success': true,
        'uri': uri,
        'size': bytes.length,
        if (text != null) 'content': text else 'content_base64': base64Encode(bytes),
        if (text == null) 'encoding': 'base64',
      };
    } catch (e) {
      return {'success': false, 'error': '$e'};
    }
  }
}

/// `shepaw store list --uri <store://...> [--depth 1]`
///
/// 默认 depth=1：只列当前目录一层（含文件夹），便于跨 agent 目录逐层下钻。
class StoreListCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description =>
      'List a store:// directory. Default --depth 1 for one folder level '
      '(includes dirs); use --depth 0 for full recursive files. Prefer this '
      'over os.file.list for store://agents/… and store://workspaces/… trees.';

  @override
  String get usage =>
      'shepaw store list --uri store://agents/0123456789abcdef --depth 1\n'
      'shepaw store list --uri store://agents/0123456789abcdef/<agent-uuid>/ --depth 1\n'
      'shepaw store list --uri store://files/0123456789abcdef/docs --depth 0';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final uri = flags['uri'];
    if (uri == null || uri.isEmpty) {
      return {'success': false, 'error': 'missing --uri'};
    }
    final depth = int.tryParse(flags['depth'] ?? '1') ?? 1;
    try {
      final parsed = parseStoreUriLoose(uri);
      final entries = await StoreService.instance.listDevice(
        deviceId: parsed.device,
        space: parsed.space,
        prefix: parsed.path.isEmpty ? null : parsed.path,
        limit: 1000,
        depth: depth,
      );
      return <String, dynamic>{
        'success': true,
        'uri': uri,
        'depth': depth,
        'entries': [for (final e in entries) e.toJson()],
      };
    } catch (e) {
      return {'success': false, 'error': '$e'};
    }
  }
}

/// Allow `store://space/device` (space root) for list; stricter [parseStoreUri]
/// still requires a path segment for read.
({String space, String device, String path}) parseStoreUriLoose(String raw) {
  final withoutQuery = raw.split('?').first;
  final rest =
      withoutQuery.startsWith('store://') ? withoutQuery.substring(8) : raw;
  final segments = rest.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.length < 2) {
    throw FormatException('bad_uri: missing space/device');
  }
  final space = segments[0];
  final device = segments[1];
  final path = segments.length <= 2
      ? ''
      : segments.sublist(2).join('/').replaceAll(RegExp(r'/+$'), '');
  for (final seg in path.split('/')) {
    if (seg.isEmpty) continue;
    if (seg.startsWith('.')) throw FormatException('bad_path: dot segment');
    if (seg == '..') throw FormatException('bad_path: path traversal');
  }
  return (space: space, device: device, path: path);
}
