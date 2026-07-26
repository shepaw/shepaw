/// memory.* / she.* 帧模型与 ACL（docs/storage_space_plan.md §8，M8）。
library;

/// peer 控制帧 type / ns。
const String kMemoryControlType = 'memory';
const String kSheControlType = 'she';

const int kMemoryProtocolVersion = 1;
const int kSheProtocolVersion = 1;

class MemoryOp {
  MemoryOp._();
  static const digestOffer = 'digest.offer';
  static const digestAck = 'digest.ack';
  static const result = 'result';
  static const error = 'error';
}

class SheOp {
  SheOp._();
  static const presence = 'presence';
  static const presenceQuery = 'presence.query';
  static const result = 'result';
  static const error = 'error';
}

class MemoryError {
  MemoryError._();
  static const untrusted = 'untrusted';
  static const disabled = 'disabled';
  static const badOp = 'bad_op';
  static const rateLimited = 'rate_limited';
}

/// 摘要类别（方案 §8.2）。
class DigestKind {
  DigestKind._();
  static const preference = 'preference';
  static const ongoing = 'ongoing';
  static const fact = 'fact';
  static const all = <String>[preference, ongoing, fact];
  static bool isValid(String k) => all.contains(k);
}

class DigestEntry {
  DigestEntry({
    required this.kind,
    required this.text,
    this.confidence = 0.8,
  });

  final String kind;
  final String text;
  final double confidence;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'text': text,
        'confidence': confidence,
      };

  static DigestEntry fromJson(Map<String, dynamic> json) => DigestEntry(
        kind: json['kind'] as String? ?? DigestKind.fact,
        text: json['text'] as String? ?? '',
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0.8,
      );
}

class MemoryFrame {
  MemoryFrame({required this.op, required this.payload, this.reqId, this.v = 1});

  final String op;
  final String? reqId;
  final int v;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': kMemoryControlType,
        'ns': kMemoryControlType,
        'op': op,
        'v': v,
        if (reqId != null) 'req_id': reqId,
        ...payload,
      };

  static MemoryFrame? tryParse(Map<String, dynamic> json) {
    if (json['ns'] != kMemoryControlType && json['type'] != kMemoryControlType) {
      return null;
    }
    final op = json['op'];
    if (op is! String) throw const FormatException('memory frame missing op');
    final payload = Map<String, dynamic>.of(json)
      ..remove('type')
      ..remove('ns')
      ..remove('op')
      ..remove('v')
      ..remove('req_id');
    return MemoryFrame(
      op: op,
      reqId: json['req_id'] as String?,
      v: json['v'] as int? ?? 1,
      payload: payload,
    );
  }
}

class SheFrame {
  SheFrame({required this.op, required this.payload, this.reqId, this.v = 1});

  final String op;
  final String? reqId;
  final int v;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': kSheControlType,
        'ns': kSheControlType,
        'op': op,
        'v': v,
        if (reqId != null) 'req_id': reqId,
        ...payload,
      };

  static SheFrame? tryParse(Map<String, dynamic> json) {
    if (json['ns'] != kSheControlType && json['type'] != kSheControlType) {
      return null;
    }
    final op = json['op'];
    if (op is! String) throw const FormatException('she frame missing op');
    final payload = Map<String, dynamic>.of(json)
      ..remove('type')
      ..remove('ns')
      ..remove('op')
      ..remove('v')
      ..remove('req_id');
    return SheFrame(
      op: op,
      reqId: json['req_id'] as String?,
      v: json['v'] as int? ?? 1,
      payload: payload,
    );
  }
}

/// 类别级能力画像（方案 §8.1：不暴露具体 Agent 名单）。
class ShePresence {
  ShePresence({
    required this.deviceId,
    required this.sheName,
    required this.online,
    required this.agentCategories,
    required this.toolCategories,
    required this.agentCount,
    this.updatedAtMs = 0,
  });

  final String deviceId;
  final String sheName;
  final bool online;
  final List<String> agentCategories;
  final List<String> toolCategories;
  final int agentCount;
  final int updatedAtMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'device': deviceId,
        'she_name': sheName,
        'online': online,
        'agent_categories': agentCategories,
        'tool_categories': toolCategories,
        'agent_count': agentCount,
        'updated_at': updatedAtMs,
      };

  static ShePresence fromJson(Map<String, dynamic> json) => ShePresence(
        deviceId: json['device'] as String? ?? '',
        sheName: json['she_name'] as String? ?? 'She',
        online: json['online'] as bool? ?? false,
        agentCategories:
            (json['agent_categories'] as List?)?.cast<String>() ?? const [],
        toolCategories:
            (json['tool_categories'] as List?)?.cast<String>() ?? const [],
        agentCount: json['agent_count'] as int? ?? 0,
        updatedAtMs: json['updated_at'] as int? ?? 0,
      );
}

/// friend 级一律拒绝 memory/she（与 store 一致）。
bool memorySheAllowed(String trustLevel) => trustLevel == 'owner';
