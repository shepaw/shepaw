import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../cli_base.dart';
import '../chat/chat_agent_scope.dart';
import '../../../services/local_database_service.dart';
import '../../../services/logger_service.dart';
import '../../../storage/artifact_service.dart';
import '../../../storage/device_identity.dart';
import '../../../storage/group_workspace_service.dart';
import '../../../storage/public_store_service.dart';
import '../../../storage/runtime_paths.dart';
import '../../../storage/local_store.dart';
import '../../../storage/store_protocol.dart';
import '../../../storage/store_service.dart';
import '../../../storage/store_uri_reader.dart';

/// 校验对群工作空间（`store://workspaces/<device>/group_<gid>/…`）的访问：
/// 执行者（[ChatAgentScope.agentId]）必须是群成员。非群工作空间 URI 返回
/// null（放行）。返回错误文案时调用方应拒绝。
Future<String?> groupWorkspaceAccessError(String uri) async {
  final parsed = parseStoreUriLoose(uri);
  if (parsed.space != StoreSpace.workspaces) return null;
  final segs = parsed.path.split('/').where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty || !segs.first.startsWith('group_')) return null;
  final gid = segs.first.substring('group_'.length);
  if (gid.isEmpty) return null;
  final agentId = ChatAgentScope.agentId.trim();
  if (agentId.isEmpty) return 'unknown executor agent id';
  final isMember = await GroupWorkspaceService.instance.isMember(gid, agentId);
  if (!isMember) return 'not a member of group workspace (group_$gid)';
  return null;
}

/// 允许相对子路径，拒绝 `..` 与点段（防路径穿越；群工作空间成员落点）。
String? sanitizeMemberRelPath(String raw) {
  final s = raw.trim().replaceAll(RegExp(r'/+$'), '');
  if (s.isEmpty) return null;
  for (final seg in s.split('/')) {
    if (seg.isEmpty) continue;
    if (seg == '..') return null;
    if (seg.startsWith('.')) return null;
  }
  return s;
}

/// [TOOLING 层] store 命名空间 - 存储空间产物/文件读写
///
/// 对应 docs/storage_space_plan.md §6.3 的 Agent 侧纪律：
/// - `store_write`（`write`）：产出写入自己设备目录，返回新 URI 即完成共享；
/// - `store_read`（`read`）：单参数 URI 读取（`artifacts` / `files` 等），分块/缓存由工具层处理；
/// - `store_list`（`list`）：默认 `--depth 1` 一层一层列目录（含 `kind:dir`），
///   便于跨 agent（`store://runtime/<device>/<agentId>/`）遍历；`--depth 0` 才递归全量文件。
/// - `store_search`（`search`）：按路径/小文本正文检索，返回 `store://` 命中。
/// - `store_events`（`events`）：commit/delete 事件；`store_spaces` / `store_declare`
///   列出或声明分区。
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
      'Store URIs (store://…): write artifacts, read files, list folders, '
      'search, events, spaces — prefer over OS paths whenever you see a '
      'store:// link';

  @override
  Map<String, CliCommand> get commands => {
        'write': StoreWriteCommand(),
        'read': StoreReadCommand(),
        'list': StoreListCommand(),
        'search': StoreSearchCommand(),
        'events': StoreEventsCommand(),
        'spaces': StoreSpacesCommand(),
        'declare': StoreDeclareCommand(),
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
      'Text via --content; binary via --file or --content-base64. '
      'Use --space public for the public partition.';

  @override
  String get usage =>
      'shepaw store write --filename report.md --content "# Q2 report" '
      '--task task-41 --desc "Q2 销售报告"\n'
      'shepaw store write --space public --filename note.md --content "hello"\n'
      'shepaw store write --filename shot.png --file /tmp/shot.png';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final filename = flags['filename'] ?? flags['name'];
    if (filename == null || filename.isEmpty) {
      return {'success': false, 'error': 'missing --filename'};
    }
    final resolved = await _resolveWriteBytes(flags);
    if (resolved.error != null) {
      return {'success': false, 'error': resolved.error};
    }
    final content = resolved.bytes;
    final space = flags['space'] ?? '';
    if (space == StoreSpace.public_) {
      try {
        final uri = await PublicStoreService.instance.writeBytes(
          relPath: filename,
          content: content,
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
    // 群工作空间：`--space workspaces --group <gid>` → 成员自己的
    // `members/<agentId>/` 子目录。只有群成员可写，且只能写自己的前缀。
    if (space == StoreSpace.workspaces) {
      final group = (flags['group'] ?? flags['gid'] ?? '').trim();
      if (group.isEmpty) {
        return {
          'success': false,
          'error': 'missing --group (workspaces write needs the group id)',
        };
      }
      final executorId =
          (flags['agent_id'] ?? flags['owner'] ?? ChatAgentScope.agentId)
              .trim();
      if (executorId.isEmpty) {
        return {'success': false, 'error': 'unknown executor agent id'};
      }
      if (!await GroupWorkspaceService.instance.isMember(group, executorId)) {
        return {
          'success': false,
          'error': 'not a member of this group workspace (group_$group)',
        };
      }
      return _writeGroupWorkspace(
        group: group,
        executorId: executorId,
        filename: filename,
        content: content,
      );
    }
    // M9: 群成员默认写共享空间——无 --space 时，群执行上下文（runtimeOwnerId
    // 非空）的产物落群工作空间 members/<agentId>/ 子目录（跨设备可见），
    // 而不是本地私有 runtime。群空间未初始化 / 非成员时回退原 runtime 路径。
    if (space.isEmpty) {
      final groupOwner = ChatAgentScope.runtimeOwnerId.trim();
      if (groupOwner.isNotEmpty) {
        final executorId =
            (flags['agent_id'] ?? flags['owner'] ?? ChatAgentScope.agentId)
                .trim();
        final ws = GroupWorkspaceService.instance;
        if (executorId.isNotEmpty &&
            await ws.isMember(groupOwner, executorId)) {
          return _writeGroupWorkspace(
            group: groupOwner,
            executorId: executorId,
            filename: filename,
            content: content,
          );
        }
        LoggerService().info(
          'store write: group member $executorId not routed to workspace '
          '(space uninitialized or not a member), falling back to runtime',
          tag: 'StoreNamespace',
        );
      }
    }

    final taskId = flags['task'] ?? 'general';
    final desc = flags['desc'];
    final agentId =
        (flags['agent_id'] ?? flags['owner'] ?? ChatAgentScope.agentId).trim();
    final channelId =
        (flags['channel_id'] ?? flags['channel'] ?? ChatAgentScope.channelId)
            .trim();
    try {
      final target = await _resolveStoreTarget(
        agentId: agentId.isNotEmpty ? agentId : ChatAgentScope.agentId,
        channelId: channelId.isNotEmpty ? channelId : null,
      );
      final reference = await ArtifactService.instance.writeArtifact(
        taskId: taskId,
        filename: filename,
        content: content,
        description: desc,
        producer: flags['producer'] ?? agentId,
        runtimeOwnerId: target.ownerId,
        channelId: target.channelId,
      );
      final uri = ArtifactService.instance
          .parseReferences(reference)
          .single
          .uri
          .toString();
      final isGroupBag = target.ownerId !=
          RuntimePaths.sanitizeSegment(
            agentId.isNotEmpty ? agentId : ChatAgentScope.agentId,
          );
      return {
        'success': true,
        'uri': uri,
        'reference': reference,
        'owner_id': target.ownerId,
        'channel_id': target.channelId,
        'bag': isGroupBag ? 'group' : 'agent',
        'note': isGroupBag
            ? '已写入本群储物袋 runtime/${target.ownerId}/（不是你个人的储物袋）。引用时原样使用 reference 单行。'
            : '已写入 runtime/${target.ownerId}/。引用时原样使用 reference 单行。',
      };
    } catch (e) {
      return {'success': false, 'error': '$e'};
    }
  }

  /// 把内容写入群工作空间成员目录 `members/<executorId>/`（跨设备可见，
  /// 仅群成员可读）。调用方负责先校验群存在与成员资格；这里只处理路径
  /// 校验与落盘。`--space workspaces` 显式路径与 M9 群成员默认路径共用。
  Future<Map<String, dynamic>> _writeGroupWorkspace({
    required String group,
    required String executorId,
    required String filename,
    required Uint8List content,
  }) async {
    final ws = GroupWorkspaceService.instance;
    final meta = await ws.loadMeta(group);
    final home = meta?.homeDevice ?? await DeviceIdentity.deviceId();
    final safeRel = sanitizeMemberRelPath(filename);
    if (safeRel == null) {
      return {
        'success': false,
        'error': 'bad --filename: path traversal not allowed',
      };
    }
    try {
      final rel = '${ws.membersDir(group, executorId)}/$safeRel';
      final uri = await StoreService.instance.writeWorkspaceFile(
        homeDeviceId: home,
        relPath: rel,
        content: content,
      );
      return {
        'success': true,
        'uri': uri,
        'space': StoreSpace.workspaces,
        'group': group,
        'note': '已写入群工作空间成员目录 members/$executorId/（跨设备可见，仅群成员可读）。',
      };
    } catch (e) {
      return {'success': false, 'error': '$e'};
    }
  }

  /// `--file` / `--content-base64` / `--content`（至少一种）。
  Future<({Uint8List bytes, String? error})> _resolveWriteBytes(
      Map<String, String> flags) async {
    final filePath = flags['file'];
    if (filePath != null && filePath.isNotEmpty) {
      final f = File(filePath);
      if (!await f.exists()) {
        return (bytes: Uint8List(0), error: 'file not found: $filePath');
      }
      return (bytes: await f.readAsBytes(), error: null);
    }
    final b64 =
        flags['content_base64'] ?? flags['content-base64'] ?? flags['base64'];
    if (b64 != null && b64.isNotEmpty) {
      try {
        return (bytes: base64Decode(b64), error: null);
      } catch (e) {
        return (bytes: Uint8List(0), error: 'invalid --content-base64: $e');
      }
    }
    final text = flags['content'];
    if (text != null && text.isNotEmpty) {
      return (bytes: Uint8List.fromList(utf8.encode(text)), error: null);
    }
    return (
      bytes: Uint8List(0),
      error: 'missing --content, --file, or --content-base64',
    );
  }

  /// 群聊 / 群绑定成员 DM → 群 runtime；单聊 → 该 Agent 的 runtime。
  /// [ChatAgentScope.runtimeOwnerId] 非空时优先（群执行器注入，避免查库失败落到自己袋）。
  Future<({String ownerId, String channelId})> _resolveStoreTarget({
    required String agentId,
    String? channelId,
  }) async {
    final scopedOwner = ChatAgentScope.runtimeOwnerId.trim();
    if (scopedOwner.isNotEmpty) {
      final owner = RuntimePaths.sanitizeSegment(scopedOwner);
      final ch = (channelId != null && channelId.isNotEmpty)
          ? RuntimePaths.sanitizeSegment(channelId)
          : owner;
      return (ownerId: owner, channelId: ch);
    }
    if (channelId == null || channelId.isEmpty) {
      final agent = RuntimePaths.sanitizeSegment(agentId);
      return (ownerId: agent, channelId: agent);
    }
    try {
      final ch = await LocalDatabaseService().getChannelById(channelId);
      return RuntimePaths.resolveStoreTarget(
        agentId: agentId,
        channelId: channelId,
        channelType: ch?.type,
        parentGroupId: ch?.parentGroupId,
        sourceGroupChannelId: ch?.sourceGroupChannelId,
      );
    } catch (_) {
      final agent = RuntimePaths.sanitizeSegment(agentId);
      return (ownerId: agent, channelId: agent);
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
    final accessErr = await groupWorkspaceAccessError(uri);
    if (accessErr != null) return {'success': false, 'error': accessErr};
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
        if (text != null)
          'content': text
        else
          'content_base64': base64Encode(bytes),
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
      'over os.file.list for store://runtime/… and store://workspaces/… trees.';

  @override
  String get usage =>
      'shepaw store list --uri store://runtime/0123456789abcdef --depth 1\n'
      'shepaw store list --uri store://runtime/0123456789abcdef/<agent-id>/ --depth 1\n'
      'shepaw store list --uri store://files/0123456789abcdef/docs --depth 0';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final uri = flags['uri'];
    if (uri == null || uri.isEmpty) {
      return {'success': false, 'error': 'missing --uri'};
    }
    final depth = int.tryParse(flags['depth'] ?? '1') ?? 1;
    final accessErr = await groupWorkspaceAccessError(uri);
    if (accessErr != null) return {'success': false, 'error': accessErr};
    try {
      final parsed = parseStoreUriLoose(uri);
      final entries = await StoreService.instance.listDevice(
        deviceId: parsed.device,
        space: parsed.space,
        prefix: parsed.path.isEmpty ? null : parsed.path,
        limit: 1000,
        depth: depth,
        computeHash: false,
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
    throw const FormatException('bad_uri: missing space/device');
  }
  final space = segments[0];
  final device = segments[1];
  final path = segments.length <= 2
      ? ''
      : segments.sublist(2).join('/').replaceAll(RegExp(r'/+$'), '');
  for (final seg in path.split('/')) {
    if (seg.isEmpty) continue;
    if (seg.startsWith('.')) {
      throw const FormatException('bad_path: dot segment');
    }
    if (seg == '..') {
      throw const FormatException('bad_path: path traversal');
    }
  }
  return (space: space, device: device, path: path);
}

int _cliInt(Map<String, String> flags, String key, int fallback) {
  final raw = flags[key];
  if (raw == null || raw.isEmpty) return fallback;
  return int.tryParse(raw) ?? fallback;
}

Map<String, dynamic> _cliStoreResult(Map<String, dynamic>? data) {
  if (data == null) return {'success': false, 'error': 'no response'};
  if (data.containsKey('_error')) {
    return {
      'success': false,
      'error': data['message'] ?? data['_error'],
      'code': data['_error'],
    };
  }
  return {'success': true, ...data};
}

/// `shepaw store search --query <q> [--space files] [--device <id>] [--uri store://…]`
class StoreSearchCommand extends CliCommand {
  @override
  String get name => 'search';

  @override
  String get description =>
      'Search store:// by path (and small text files by body). Prefer this '
      'over recursively listing when looking for a filename or keyword.';

  @override
  String get usage => 'shepaw store search --query report --space files\n'
      'shepaw store search --query unique-token --uri store://runtime/<device>/<agent-id>/';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final q = (flags['query'] ?? flags['q'] ?? '').trim();
    if (q.isEmpty) {
      return {'success': false, 'error': 'missing --query'};
    }
    String? space = flags['space'];
    String? device = flags['device'];
    var pathPrefix = '';
    final uri = flags['uri'];
    if (uri != null && uri.isNotEmpty) {
      final accessErr = await groupWorkspaceAccessError(uri);
      if (accessErr != null) return {'success': false, 'error': accessErr};
      try {
        final parsed = parseStoreUriLoose(uri);
        space = parsed.space;
        device = parsed.device;
        pathPrefix = parsed.path.isEmpty ? '' : '${parsed.path}/';
      } catch (e) {
        return {'success': false, 'error': '$e'};
      }
    }
    device ??= await DeviceIdentity.deviceId();
    try {
      final hits = await StoreService.instance.searchDevice(
        q: q,
        deviceId: device,
        space: (space == null || space.isEmpty) ? null : space,
        limit: _cliInt(flags, 'limit', 50),
      );
      final filtered = [
        for (final hit in hits)
          if (pathPrefix.isEmpty ||
              '${hit['path'] ?? ''}'.startsWith(pathPrefix))
            hit,
      ];
      return {
        'success': true,
        'query': q,
        'total': filtered.length,
        'results': filtered,
      };
    } on StoreException catch (e) {
      return {
        'success': false,
        'error': e.message.isEmpty ? e.code : e.message,
        'code': e.code,
      };
    } catch (e) {
      return {'success': false, 'error': '$e'};
    }
  }
}

/// `shepaw store events [--since 0] [--limit 50] [--kind file.committed]`
class StoreEventsCommand extends CliCommand {
  @override
  String get name => 'events';

  @override
  String get description =>
      'List store events (commit/delete) since a seq. Empty bus returns '
      'events=[] and latest_seq=0.';

  @override
  String get usage => 'shepaw store events --since 0 --limit 50\n'
      'shepaw store events --kind file.committed';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    try {
      return _cliStoreResult(await StoreService.instance.eventsList(
        since: _cliInt(flags, 'since', 0),
        limit: _cliInt(flags, 'limit', 50),
        kind: (flags['kind'] ?? '').trim().isEmpty ? null : flags['kind'],
      ));
    } catch (e) {
      return {'success': false, 'error': '$e'};
    }
  }
}

/// `shepaw store spaces`
class StoreSpacesCommand extends CliCommand {
  @override
  String get name => 'spaces';

  @override
  String get description =>
      'List builtin and declared store spaces (name + visibility).';

  @override
  String get usage => 'shepaw store spaces';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    try {
      return _cliStoreResult(await StoreService.instance.spaceList());
    } catch (e) {
      return {'success': false, 'error': '$e'};
    }
  }
}

/// `shepaw store declare --name models [--visibility shared]`
class StoreDeclareCommand extends CliCommand {
  @override
  String get name => 'declare';

  @override
  String get description =>
      'Declare a custom space on this device (loopback/admin only). '
      'Name: [a-z][a-z0-9-]{0,31}.';

  @override
  String get usage => 'shepaw store declare --name models --visibility shared';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final name = (flags['name'] ?? '').trim();
    if (name.isEmpty) {
      return {'success': false, 'error': 'missing --name'};
    }
    try {
      return _cliStoreResult(await StoreService.instance.spaceDeclare(
        name: name,
        visibility: flags['visibility'] ?? 'private',
        encryption: flags['encryption'] ?? 'none',
        retention: flags['retention'] ?? 'none',
        importGrant:
            flags['import_grant'] ?? flags['import-grant'] ?? 'allowed',
      ));
    } catch (e) {
      return {'success': false, 'error': '$e'};
    }
  }
}
