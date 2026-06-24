import 'dart:convert';
import 'dart:typed_data';

import '../../services/noise/noise_envelope.dart';

/// 配对请求（Noise msg1 payload，Initiator/Scanner → Responder/QR-Generator）
class PairingRequest {
  /// 配对码（证明扫描了 QR）
  final String pairingCode;

  /// 发起方设备名称
  final String deviceName;

  /// 发起方设备 UUID
  final String deviceId;

  /// 发起方的 Channel 端点（供对方日后通过外网连接自己，可选）
  final String? channelEndpoint;

  /// 发起方的内网端点（可选）
  final String? localEndpoint;

  /// 时间戳（毫秒）
  final int timestamp;

  PairingRequest({
    required this.pairingCode,
    required this.deviceName,
    required this.deviceId,
    this.channelEndpoint,
    this.localEndpoint,
    required this.timestamp,
  });

  factory PairingRequest.fromJson(Map<String, dynamic> json) {
    return PairingRequest(
      pairingCode: json['pairing_code'] as String,
      deviceName: json['device_name'] as String,
      deviceId: json['device_id'] as String,
      channelEndpoint: json['channel_endpoint'] as String?,
      localEndpoint: json['local_endpoint'] as String?,
      timestamp: json['timestamp'] as int,
    );
  }

  Map<String, dynamic> toJson() => {
    'pairing_code': pairingCode,
    'device_name': deviceName,
    'device_id': deviceId,
    if (channelEndpoint != null) 'channel_endpoint': channelEndpoint,
    if (localEndpoint != null) 'local_endpoint': localEndpoint,
    'timestamp': timestamp,
  };

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  factory PairingRequest.fromBytes(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    return PairingRequest.fromJson(json);
  }
}

/// 配对响应（Noise msg2 payload，Responder/QR-Generator → Initiator/Scanner）
class PairingResponse {
  /// 是否接受配对
  final bool accepted;

  /// 响应方设备名称
  final String deviceName;

  /// 响应方设备 UUID
  final String deviceId;

  /// 配对关系唯一 ID（双方共享）
  final String peerId;

  /// 响应方的 Channel 端点（可选，无 Channel 时为 null）
  final String? channelEndpoint;

  /// 响应方的内网端点（可选）
  final String? localEndpoint;

  /// 拒绝原因（accepted=false 时）
  final String? rejectReason;

  PairingResponse({
    required this.accepted,
    required this.deviceName,
    required this.deviceId,
    required this.peerId,
    this.channelEndpoint,
    this.localEndpoint,
    this.rejectReason,
  });

  factory PairingResponse.fromJson(Map<String, dynamic> json) {
    if (json['type'] == 'reconnect_ack') {
      throw StateError(
        '主存储设备未处于扫码配对状态。请在 PC 上重新打开「展示手机扫码登录二维码」，'
        '保持页面在前台后再扫描。',
      );
    }
    final accepted = json['accepted'];
    if (accepted is! bool) {
      throw StateError('无效的配对响应（缺少 accepted 字段）');
    }
    return PairingResponse(
      accepted: accepted,
      deviceName: json['device_name'] as String,
      deviceId: json['device_id'] as String,
      peerId: json['peer_id'] as String,
      channelEndpoint: json['channel_endpoint'] as String?,
      localEndpoint: json['local_endpoint'] as String?,
      rejectReason: json['reject_reason'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'accepted': accepted,
    'device_name': deviceName,
    'device_id': deviceId,
    'peer_id': peerId,
    if (channelEndpoint != null) 'channel_endpoint': channelEndpoint,
    if (localEndpoint != null) 'local_endpoint': localEndpoint,
    if (rejectReason != null) 'reject_reason': rejectReason,
  };

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  factory PairingResponse.fromBytes(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    return PairingResponse.fromJson(json);
  }
}

/// 连接模式
enum PeerConnectMode {
  /// 内网直连（同一局域网，WebSocket 直连）
  local,
  /// 外网穿透（通过 Channel 服务中继）
  channel,
}

/// QR 码解析后的配对信息
class PeerPairingInfo {
  /// 内网直连端点（ws://192.168.x.x:port/peer/ws）
  final String? localEndpoint;

  /// Channel 外网端点（wss://channel.xxx.com/proxy/.../peer/ws）
  final String? channelEndpoint;

  /// 配对码
  final String code;

  /// 对方公钥指纹（前 16 位 hex）
  final String fingerprint;

  /// 对方 X25519 公钥（32 bytes）
  final Uint8List publicKey;

  PeerPairingInfo({
    this.localEndpoint,
    this.channelEndpoint,
    required this.code,
    required this.fingerprint,
    required this.publicKey,
  }) : assert(localEndpoint != null || channelEndpoint != null,
          'At least one endpoint must be provided');

  /// 获取首选连接端点（优先内网）
  String get preferredEndpoint => localEndpoint ?? channelEndpoint!;

  /// 连接模式
  PeerConnectMode get mode =>
      localEndpoint != null ? PeerConnectMode.local : PeerConnectMode.channel;

  /// 从 QR 码内容解析
  ///
  /// 格式:
  ///   shepaw://peer?local=<WS_URL>&channel=<WS_URL>&code=<6-CHAR>#fp=<fingerprint>&pk=<base64url-pubkey>
  ///
  /// `local` 和 `channel` 至少有一个存在。
  /// 仅内网配对时只有 `local`，仅外网时只有 `channel`，两者都有时优先尝试 `local`。
  static PeerPairingInfo? tryParse(String qrContent) {
    try {
      final uri = Uri.parse(qrContent);
      if (uri.scheme != 'shepaw' || uri.host != 'peer') return null;

      final localEndpoint = uri.queryParameters['local'];
      final channelEndpoint = uri.queryParameters['channel'];
      // 兼容旧格式 endpoint 参数
      final legacyEndpoint = uri.queryParameters['endpoint'];
      final code = uri.queryParameters['code'];
      if (code == null) return null;

      // 至少有一个端点
      final effectiveLocal = localEndpoint;
      final effectiveChannel = channelEndpoint ?? legacyEndpoint;
      if (effectiveLocal == null && effectiveChannel == null) return null;

      // Fragment 中包含 fp 和 pk
      final fragment = uri.fragment;
      final fragParams = Uri.splitQueryString(fragment);
      final fp = fragParams['fp'];
      final pk = fragParams['pk'];
      if (fp == null || pk == null) return null;

      final publicKey = fromBase64Url(pk);
      if (publicKey.length != 32) return null;

      return PeerPairingInfo(
        localEndpoint: effectiveLocal,
        channelEndpoint: effectiveChannel,
        code: code,
        fingerprint: fp,
        publicKey: publicKey,
      );
    } catch (_) {
      return null;
    }
  }

  /// 生成 QR 码内容
  static String encode({
    String? localEndpoint,
    String? channelEndpoint,
    required String code,
    required String fingerprint,
    required Uint8List publicKey,
  }) {
    assert(localEndpoint != null || channelEndpoint != null);
    final pk = toBase64Url(publicKey);
    final params = <String>[];
    if (localEndpoint != null) {
      params.add('local=${Uri.encodeComponent(localEndpoint)}');
    }
    if (channelEndpoint != null) {
      params.add('channel=${Uri.encodeComponent(channelEndpoint)}');
    }
    params.add('code=$code');
    return 'shepaw://peer?${params.join('&')}#fp=$fingerprint&pk=$pk';
  }
}
