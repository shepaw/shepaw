/// 本机 hub 的 v3 通道（G4）：`pouch.sock`。
///
/// App 装在 hub 那台机器上、还没配对时，读写的仍是 hub 的同一个 v3 袋子。
/// hub 只在本机开一条 Unix socket（模式 `0600`，主体固定为 owner），帧和
/// 手机那条 `pouch` 帧完全一样（见 `crates/pouch/src/local_socket.rs`）。
/// socket 不在就返回 null，调用方按 `notPaired` 处理 —— 不静默降级去读目录。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../peer/services/local_cli_dial.dart' show cliHubRootFromEnv;

/// 本机 hub 的 socket 文件名（hub 侧 `hub_root().join("pouch.sock")`）。
const String kLocalPouchSocketName = 'pouch.sock';

/// 本机 hub 的通道：socket 路径 + `hub.json` 里的活跃袋子。
class LocalPouchEndpoint {
  const LocalPouchEndpoint({
    required this.socketPath,
    required this.pouchId,
  });

  final String socketPath;
  final String pouchId;
}

/// 从 `hub.json` 的内容里取 `active_pouch`。
String? activePouchFromHubJson(Object? decoded) {
  if (decoded is! Map) return null;
  final value = decoded['active_pouch'];
  if (value is! String) return null;
  final id = value.trim();
  return id.isEmpty ? null : id;
}

/// 本机有没有可用的 hub 通道。
///
/// 两个条件缺一不可：
/// - `<hubRoot>/pouch.sock` 是个 Unix socket（目录里的同名普通文件不算）；
/// - `<hubRoot>/hub.json` 有 `active_pouch`（没有活跃袋子就没法拼帧的 `pouch_id`）。
///
/// [hubRoot] / [socketPath] / [hubJson] 只给测试替换用。
Future<LocalPouchEndpoint?> findLocalPouchEndpoint({
  String? hubRoot,
  String? socketPath,
  File? hubJson,
}) async {
  final root = hubRoot ?? cliHubRootFromEnv(Platform.environment);
  final path = socketPath ?? p.join(root, kLocalPouchSocketName);
  if (FileSystemEntity.typeSync(path) != FileSystemEntityType.unixDomainSock) {
    return null;
  }
  final file = hubJson ?? File(p.join(root, 'hub.json'));
  String pouchId;
  try {
    if (!await file.exists()) return null;
    pouchId = activePouchFromHubJson(jsonDecode(await file.readAsString())) ?? '';
  } catch (_) {
    return null;
  }
  if (pouchId.isEmpty) return null;
  return LocalPouchEndpoint(socketPath: path, pouchId: pouchId);
}
