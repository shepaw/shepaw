/// sync.* 帧模型与编解码。
///
/// 权威定义见 docs/sync_protocol_spec.md v1。所有同步帧复用 PeerMessage
/// 控制帧通道，载荷为 JSON：`{"ns":"sync","op":..., "epoch":..., "v":...}`。
library;

/// 协议版本。新增 op 或必填字段时 +1。
const int kSyncProtocolVersion = 1;

/// 同步帧命名空间。
const String kSyncNs = 'sync';

/// peer 层控制帧路由 type（PeerConnection._controlTypes 中注册的值）。
const String kSyncControlType = 'sync';

/// docs/sync_protocol_spec.md §4 操作清单。
class SyncOp {
  SyncOp._();

  // 连接 rendezvous（§4）
  static const hello = 'hello';

  // adopting（第 6 节）
  static const adoptBegin = 'adopt.begin';
  static const adoptBatch = 'adopt.batch';
  static const adoptDone = 'adopt.done';

  // snapshot_sync（第 7 节）
  static const snapshotBegin = 'snapshot.begin';
  static const snapshotNext = 'snapshot.next';
  static const snapshotChunk = 'snapshot.chunk';
  static const snapshotDone = 'snapshot.done';

  // active（第 5 节）
  static const pull = 'pull';
  static const changes = 'changes';
  static const ack = 'ack';
  static const notify = 'notify';

  // stats（第 8 节）
  static const stats = 'stats';

  static const error = 'error';
}

/// docs/sync_protocol_spec.md §1 错误码。
class SyncErrorCode {
  SyncErrorCode._();

  static const epochMismatch = 'epoch_mismatch';
  static const unsupportedVersion = 'unsupported_version';
  static const notPaired = 'not_paired';
  static const roleInvalid = 'role_invalid';
  static const cursorTooOld = 'cursor_too_old';
  static const busy = 'busy';
  static const internal = 'internal';
}

/// 一帧 sync.* 消息。字段不合法时构造即抛 [FormatException]，
/// 让接收侧在帧路由边界统一转成 error 帧。
class SyncFrame {
  SyncFrame({
    required this.op,
    required this.epoch,
    required this.payload,
    this.v = kSyncProtocolVersion,
  });

  final String op;
  final int epoch;
  final int v;

  /// op 特有字段（不含 ns/op/epoch/v）。
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': kSyncControlType,
        'ns': kSyncNs,
        'op': op,
        'epoch': epoch,
        'v': v,
        ...payload,
      };

  /// 从控制帧 JSON 解析。非 sync 帧返回 null（交由其他处理器）。
  static SyncFrame? tryParse(Map<String, dynamic> json) {
    if (json['ns'] != kSyncNs) return null;
    final op = json['op'];
    if (op is! String) {
      throw const FormatException('sync frame missing op');
    }
    final epoch = json['epoch'];
    if (epoch is! int) {
      throw const FormatException('sync frame missing epoch');
    }
    final v = json['v'];
    final payload = Map<String, dynamic>.of(json)
      ..remove('type')
      ..remove('ns')
      ..remove('op')
      ..remove('epoch')
      ..remove('v');
    return SyncFrame(
      op: op,
      epoch: epoch,
      v: v is int ? v : 0,
      payload: payload,
    );
  }

  /// 该帧的协议版本是否可处理（spec §10：高于本版视为不兼容）。
  bool get versionSupported => v >= 1 && v <= kSyncProtocolVersion;

  @override
  String toString() => 'SyncFrame($op epoch=$epoch v=$v)';
}

/// 构造通用错误帧（spec §1）。
SyncFrame syncErrorFrame({
  required int epoch,
  required String refOp,
  required String code,
  String? message,
}) =>
    SyncFrame(
      op: SyncOp.error,
      epoch: epoch,
      payload: <String, dynamic>{
        'ref_op': refOp,
        'code': code,
        if (message != null) 'message': message,
      },
    );
