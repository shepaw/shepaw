import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../../services/noise/noise_envelope.dart';

/// 公钥 → 16 hex 指纹（与 NoiseIdentity.fingerprintHex 同一算法）。
String _fingerprintOf(Uint8List publicKey) {
  final digest = crypto.sha256.convert(publicKey).bytes;
  final sb = StringBuffer();
  for (var i = 0; i < 8; i++) {
    sb.write(digest[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

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
    return PairingResponse(
      accepted: json['accepted'] as bool,
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

/// QR 中设备名允许的最大 Unicode rune 数。
///
/// 与 hub 侧 `PEER_QR_NAME_MAX_RUNES` 保持一致（跨仓 golden 测试的前提）。
/// 刻意低于 `/peer/device-name` 校验的 64 字符上限：百分号编码的中文在 QR 里
/// 每个字符要占 9 个 ASCII 字节，payload 长度直接决定二维码版本（即扫码难度）。
/// 这个不一致是刻意的，两边不需要对齐。
const int kPeerQrNameMaxRunes = 32;

/// 截断到 [max] 个 Unicode rune。
///
/// 不能用 `String.substring` —— 它数的是 UTF-16 code unit，在 emoji 处切开会留下
/// 孤立 surrogate，编码后输出乱码。
String _truncateRunes(String s, int max) {
  if (s.length <= max) return s;
  return String.fromCharCodes(s.runes.take(max));
}

/// 不可见 / 双向控制字符：C0 控制符（含 \n \t）、DEL、LRM/RLM、
/// 双向覆盖符（LRE…RLO）与双向隔离符（LRI…PDI）。
final RegExp _invisibleNameChars = RegExp(
  r'[\u0000-\u001F\u007F\u200E\u200F\u202A-\u202E\u2066-\u2069]',
);

final RegExp _whitespaceRuns = RegExp(r'\s+');

/// 剥掉不可见 / 双向控制字符，折叠连续空白，并按 rune 截断。
///
/// 不是装饰性问题：`U+202E`（RIGHT-TO-LEFT OVERRIDE）能让 "Mac" 在视觉上渲染成
/// 别的东西，恰好是本功能要防的那类谎言。设备名是对方自填的，不可信。
String _sanitizeDisplayName(String raw) {
  final cleaned = raw
      .replaceAll(_invisibleNameChars, '')
      .replaceAll(_whitespaceRuns, ' ')
      .trim();
  return _truncateRunes(cleaned, kPeerQrNameMaxRunes);
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

  /// 对方**自述**的设备名（原始值，未清洗、未截断）。
  ///
  /// **未经认证**：这是对方在二维码 query 里自填的标签，不可作为身份依据。
  /// 信任锚点始终是 [fingerprint] / [publicKey] —— 能换链接的人也能换名字。
  /// 展示请用 [displayName]。
  final String? name;

  PeerPairingInfo({
    this.localEndpoint,
    this.channelEndpoint,
    required this.code,
    required this.fingerprint,
    required this.publicKey,
    this.name,
  }) : assert(localEndpoint != null || channelEndpoint != null,
          'At least one endpoint must be provided');

  /// 供展示的设备名：已剥掉控制/双向字符、折叠空白、按 rune 截断。
  /// 没有名字时返回 null。
  String? get displayName {
    final raw = name;
    if (raw == null) return null;
    final cleaned = _sanitizeDisplayName(raw);
    return cleaned.isEmpty ? null : cleaned;
  }

  /// 复制并覆盖指定字段（未传的字段保持原值）。
  ///
  /// 存在的意义是别再出现「逐字段手工重建」—— 那种写法每加一个字段都会静默丢数据。
  PeerPairingInfo copyWith({
    String? localEndpoint,
    String? channelEndpoint,
    String? code,
    String? fingerprint,
    Uint8List? publicKey,
    String? name,
  }) {
    return PeerPairingInfo(
      localEndpoint: localEndpoint ?? this.localEndpoint,
      channelEndpoint: channelEndpoint ?? this.channelEndpoint,
      code: code ?? this.code,
      fingerprint: fingerprint ?? this.fingerprint,
      publicKey: publicKey ?? this.publicKey,
      name: name ?? this.name,
    );
  }

  /// 获取首选连接端点（优先内网）
  String get preferredEndpoint => localEndpoint ?? channelEndpoint!;

  /// 连接模式
  PeerConnectMode get mode =>
      localEndpoint != null ? PeerConnectMode.local : PeerConnectMode.channel;

  /// 从 QR 码内容解析
  ///
  /// 格式:
  ///   shepaw://peer?local=<WS_URL>&channel=<WS_URL>&code=<8-CHAR>&name=<LABEL>#fp=<fingerprint>&pk=<base64url-pubkey>
  ///
  /// `local` 和 `channel` 至少有一个存在。
  /// 仅内网配对时只有 `local`，仅外网时只有 `channel`，两者都有时优先尝试 `local`。
  /// `name` 可选，是对方自述的设备名（未经认证，见 [name]）。
  /// 多余的未知 query 参数一律忽略（前向兼容）。
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

      // 安全：fp 必须等于公钥哈希（防攻击者 QR 自报受害设备 fingerprint）。
      if (_fingerprintOf(publicKey) != fp.toLowerCase()) return null;

      // 名字存原始值；清洗与截断只在 displayName getter 里做，
      // 这样往返测试是精确的，防伪造逻辑也能单独测。
      final rawName = uri.queryParameters['name'];
      final name = (rawName != null && rawName.trim().isNotEmpty) ? rawName : null;

      return PeerPairingInfo(
        localEndpoint: effectiveLocal,
        channelEndpoint: effectiveChannel,
        code: code,
        fingerprint: fp,
        publicKey: publicKey,
        name: name,
      );
    } catch (_) {
      return null;
    }
  }

  /// 生成 QR 码内容
  ///
  /// [name] 是可选的设备名（未经认证的自述标签）。空 / 纯空白会被整个省略，
  /// 使旧格式 QR 与「新格式但无名字」产出字节相同的串。
  /// 必须与 hub 侧 `buildPeerQrPayload` 逐字节一致（跨仓 golden 测试）：
  /// `name` 是最后一个 query 参数，空格编码为 `%20` 而非 `+`。
  static String encode({
    String? localEndpoint,
    String? channelEndpoint,
    required String code,
    required String fingerprint,
    required Uint8List publicKey,
    String? name,
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
    if (name != null && name.trim().isNotEmpty) {
      // Uri.encodeComponent 用 %20 编码空格（不是 +），与 encodeURIComponent 一致。
      params.add('name=${Uri.encodeComponent(_truncateRunes(name, kPeerQrNameMaxRunes))}');
    }
    return 'shepaw://peer?${params.join('&')}#fp=$fingerprint&pk=$pk';
  }
}
