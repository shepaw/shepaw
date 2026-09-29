import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 这份安装是储物袋的主机，还是连到主机上的客户端。
///
/// 没有 `.system/pouch_role.json` 时视为主机，已有设备不用改配置。
enum PouchRuntimeKind { host, client }

class PouchRole {
  const PouchRole.host()
      : kind = PouchRuntimeKind.host,
        hostPeerId = null;

  const PouchRole.client(String peerId)
      : kind = PouchRuntimeKind.client,
        hostPeerId = peerId;

  final PouchRuntimeKind kind;
  final String? hostPeerId;

  bool get isHost => kind == PouchRuntimeKind.host;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'role': kind.name,
        if (hostPeerId != null) 'host_peer_id': hostPeerId,
      };

  static PouchRole fromJson(Map<String, dynamic> json) {
    final role = json['role'] as String? ?? 'host';
    if (role == 'client') {
      return PouchRole.client((json['host_peer_id'] as String?)?.trim() ?? '');
    }
    return const PouchRole.host();
  }
}

class PouchRoleStore {
  PouchRoleStore(this.root);

  final Directory root;

  static const fileName = 'pouch_role.json';

  File get file => File(p.join(root.path, '.system', fileName));

  Future<PouchRole> load() async {
    if (!await file.exists()) return const PouchRole.host();
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const FormatException('pouch role root must be an object');
    }
    return PouchRole.fromJson(decoded.cast<String, dynamic>());
  }

  Future<void> save(PouchRole role) async {
    if (role.kind == PouchRuntimeKind.client &&
        (role.hostPeerId == null || role.hostPeerId!.trim().isEmpty)) {
      throw ArgumentError('client role requires hostPeerId');
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(role.toJson()));
  }
}

/// 这一回合在本机跑，还是交给主机。
class PouchTurnRoute {
  const PouchTurnRoute.local()
      : runLocal = true,
        hostPeerId = null;

  const PouchTurnRoute.forward(this.hostPeerId) : runLocal = false;

  final bool runLocal;
  final String? hostPeerId;

  static PouchTurnRoute decide(PouchRole role) {
    if (role.isHost) return const PouchTurnRoute.local();
    final peerId = role.hostPeerId?.trim() ?? '';
    if (peerId.isEmpty) {
      throw StateError('客户端未指定储物袋主机');
    }
    return PouchTurnRoute.forward(peerId);
  }
}
