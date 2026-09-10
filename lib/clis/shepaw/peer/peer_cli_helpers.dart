import '../../../peer/models/peer_store_share.dart';
import '../../../peer/services/peer_pairing_service.dart';
import '../../../peer/services/peer_storage_service.dart';
import '../../../services/event/event_bus.dart';
import '../../../services/local_database_service.dart';
import '../../../storage/store_protocol.dart' show TrustLevel;
import '../chat/chat_agent_scope.dart';

/// Initiator 命令：解析或生成 correlation_id。
String resolveInitiatorCorrelation(Map<String, String> flags) {
  final fromFlag = flags['correlation']?.trim();
  if (fromFlag != null && fromFlag.isNotEmpty) return fromFlag;
  final scoped = ChatAgentScope.correlationId;
  if (scoped != null && scoped.isNotEmpty) return scoped;
  return generateCorrelationId();
}

/// Continuator 命令：从 pairing session 继承 correlation_id。
String? resolveContinuatorCorrelation() {
  return PeerPairingService.instance.sessionCorrelationId;
}

Map<String, dynamic> withCorrelationId(
  Map<String, dynamic> result,
  String? correlationId,
) {
  if (correlationId == null || correlationId.isEmpty) return result;
  return {...result, 'correlation_id': correlationId};
}

/// 解析 `--trust` flag，默认 owner。
String parsePeerTrustLevel(String? raw) {
  final v = (raw ?? TrustLevel.owner).trim().toLowerCase();
  if (v == TrustLevel.friend) return TrustLevel.friend;
  return TrustLevel.owner;
}

/// 与配对确认 UI 对齐：解析要分享给对端的 Agent 勾选。
///
/// `--agents`：
/// - 省略或 `all`：所有 allowExternalAccess 的本机 Agent 默认分享
/// - `none`：全部不分享
/// - 逗号分隔 agent id：仅分享列出的 Agent
Future<Map<String, bool>?> resolveAgentSharesForAccept({
  required IncomingPairingRequest request,
  String? agentsFlag,
}) async {
  final db = LocalDatabaseService();
  final eligible = (await db.getAllRemoteAgents())
      .where((a) => a.isLocal && a.allowExternalAccess)
      .toList();
  if (eligible.isEmpty) return null;

  final flag = (agentsFlag ?? 'all').trim().toLowerCase();
  if (flag == 'none') {
    return {for (final a in eligible) a.id: false};
  }

  final existing =
      await PeerStorageService().getPeerByFingerprint(request.fingerprint);
  final saved = existing != null
      ? await PeerStorageService().getAgentShares(existing.id)
      : <String, bool>{};
  final hasSaved = saved.isNotEmpty;

  if (flag != 'all') {
    final selected = flag
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    return {for (final a in eligible) a.id: selected.contains(a.id)};
  }

  return {
    for (final a in eligible)
      a.id: hasSaved ? (saved[a.id] ?? true) : true,
  };
}

/// 与配对确认 UI 对齐：解析储物袋分享条目。
Future<List<PeerStoreShareEntry>> resolveStoreSharesForAccept({
  required IncomingPairingRequest request,
  required String trustLevel,
}) async {
  if (trustLevel != TrustLevel.owner) return [];

  final existing =
      await PeerStorageService().getPeerByFingerprint(request.fingerprint);
  if (existing != null) {
    final entries =
        await PeerStorageService().getSharedStoreEntries(existing.id);
    if (entries.isNotEmpty) return entries;
  }
  return PeerStorageService.ownerDefaultStoreShares();
}

/// 从 QR 深链提取 8 位配对码。
String? pairingCodeFromQr(String? qrContent) {
  if (qrContent == null || qrContent.isEmpty) return null;
  try {
    return Uri.parse(qrContent).queryParameters['code'];
  } catch (_) {
    return null;
  }
}
