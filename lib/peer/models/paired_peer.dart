import 'dart:convert';
import 'dart:typed_data';

import '../../l10n/app_localizations.dart';

/// 配对设备连接状态
enum PeerConnectionState {
  disconnected,
  connecting,
  connected;

  String toJson() => name;

  static PeerConnectionState fromJson(String value) {
    return PeerConnectionState.values.firstWhere(
      (e) => e.name == value,
      orElse: () => PeerConnectionState.disconnected,
    );
  }
}

extension PeerConnectionStateL10n on PeerConnectionState {
  /// 设备列表中的连接状态文案。
  String listStatusLabel(
    AppLocalizations l10n, {
    bool showE2eWhenConnected = false,
  }) {
    switch (this) {
      case PeerConnectionState.connected:
        return showE2eWhenConnected
            ? l10n.peerList_connectedE2e
            : l10n.peerList_connected;
      case PeerConnectionState.connecting:
        return l10n.peerChat_statusConnecting;
      case PeerConnectionState.disconnected:
        return l10n.peerList_disconnected;
    }
  }
}

/// 本机在这段配对关系中的角色
enum PeerPairingRole {
  /// 本机主动发起配对（扫描了对方的二维码）
  initiator,

  /// 本机被动接受配对（展示二维码、被对方扫描）
  responder;

  String toJson() => name;

  static PeerPairingRole? fromJson(String? value) {
    if (value == null) return null;
    for (final r in PeerPairingRole.values) {
      if (r.name == value) return r;
    }
    return null;
  }
}

/// 已配对的远端 Shepaw 设备
class PairedPeer {
  /// 配对关系唯一 ID
  final String id;

  /// 对方设备名称
  final String deviceName;

  /// 对方设备 UUID
  final String deviceId;

  /// 对方 X25519 公钥 (32 bytes)
  final Uint8List publicKey;

  /// 公钥 SHA-256 指纹（前 16 位 hex）
  final String fingerprint;

  /// 对方的 Channel 端点 URL（用于外网 NAT 穿透，可选）
  final String? channelEndpoint;

  /// 对方上次已知的内网地址（ws://ip:port/peer/ws，可选）
  final String? localEndpoint;

  /// 配对时间（毫秒时间戳）
  final int pairedAt;

  /// 最后在线时间（毫秒时间戳）
  final int? lastSeen;

  /// 连接状态（运行时状态，不持久化）
  final PeerConnectionState state;

  /// 是否已屏蔽
  final bool isBlocked;

  /// 本机在这段配对中的角色（发起方 / 被连接方）。历史数据可能为 null。
  final PeerPairingRole? pairingRole;

  PairedPeer({
    required this.id,
    required this.deviceName,
    required this.deviceId,
    required this.publicKey,
    required this.fingerprint,
    this.channelEndpoint,
    this.localEndpoint,
    required this.pairedAt,
    this.lastSeen,
    this.state = PeerConnectionState.disconnected,
    this.isBlocked = false,
    this.pairingRole,
  });

  /// 获取首选连接端点（优先内网直连）
  String? get preferredEndpoint => localEndpoint ?? channelEndpoint;

  /// 是否有可用端点
  bool get hasEndpoint => channelEndpoint != null || localEndpoint != null;

  /// 角色短标签（用于会话列表/标题栏小徽标）。
  String? pairingRoleShortLabel(AppLocalizations l10n) {
    switch (pairingRole) {
      case PeerPairingRole.initiator:
        return l10n.peerRole_initiatorShort;
      case PeerPairingRole.responder:
        return l10n.peerRole_responderShort;
      case null:
        return null;
    }
  }

  /// 角色完整描述（用于设备详情页）。
  String? pairingRoleDescription(AppLocalizations l10n) {
    switch (pairingRole) {
      case PeerPairingRole.initiator:
        return l10n.peerRole_initiatorDesc;
      case PeerPairingRole.responder:
        return l10n.peerRole_responderDesc;
      case null:
        return null;
    }
  }

  /// 从 JSON（数据库行）创建
  factory PairedPeer.fromJson(Map<String, dynamic> json) {
    return PairedPeer(
      id: json['id'] as String,
      deviceName: json['device_name'] as String,
      deviceId: json['device_id'] as String,
      publicKey: Uint8List.fromList(
        (jsonDecode(json['public_key'] as String) as List).cast<int>(),
      ),
      fingerprint: json['fingerprint'] as String,
      channelEndpoint: json['channel_endpoint'] as String?,
      localEndpoint: json['local_endpoint'] as String?,
      pairedAt: json['paired_at'] as int,
      lastSeen: json['last_seen'] as int?,
      state: PeerConnectionState.disconnected, // 运行时状态，不从 DB 恢复
      isBlocked: (json['is_blocked'] as int? ?? 0) == 1,
      pairingRole: PeerPairingRole.fromJson(json['pairing_role'] as String?),
    );
  }

  /// 转换为 JSON（用于数据库存储）
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'device_name': deviceName,
      'device_id': deviceId,
      'public_key': jsonEncode(publicKey.toList()),
      'fingerprint': fingerprint,
      'channel_endpoint': channelEndpoint,
      'local_endpoint': localEndpoint,
      'paired_at': pairedAt,
      'last_seen': lastSeen,
      'is_blocked': isBlocked ? 1 : 0,
      'pairing_role': pairingRole?.toJson(),
    };
  }

  /// 复制并修改部分字段
  PairedPeer copyWith({
    String? id,
    String? deviceName,
    String? deviceId,
    Uint8List? publicKey,
    String? fingerprint,
    String? channelEndpoint,
    String? localEndpoint,
    int? pairedAt,
    int? lastSeen,
    PeerConnectionState? state,
    bool? isBlocked,
    PeerPairingRole? pairingRole,
  }) {
    return PairedPeer(
      id: id ?? this.id,
      deviceName: deviceName ?? this.deviceName,
      deviceId: deviceId ?? this.deviceId,
      publicKey: publicKey ?? this.publicKey,
      fingerprint: fingerprint ?? this.fingerprint,
      channelEndpoint: channelEndpoint ?? this.channelEndpoint,
      localEndpoint: localEndpoint ?? this.localEndpoint,
      pairedAt: pairedAt ?? this.pairedAt,
      lastSeen: lastSeen ?? this.lastSeen,
      state: state ?? this.state,
      isBlocked: isBlocked ?? this.isBlocked,
      pairingRole: pairingRole ?? this.pairingRole,
    );
  }

  @override
  String toString() => 'PairedPeer($deviceName, fp=$fingerprint)';
}
