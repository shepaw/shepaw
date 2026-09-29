import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../storage/agent_roster.dart';
import '../storage/pouch_role.dart';
import '../storage/store_service.dart';
import 'models/paired_peer.dart';
import 'services/peer_storage_service.dart';

/// 主机把工人 Hub 报上来的 Agent 名单写进储物袋名册。
///
/// 客户端不写。握手完成时还没有这份名单，要等 `agent_list_resp`。
class PouchRosterSync {
  PouchRosterSync._();

  static List<HubAgentReport> reportsFromAgentList(List<Object?> agents) {
    final out = <HubAgentReport>[];
    for (final raw in agents) {
      if (raw is! Map) continue;
      final id = _text(raw['id']);
      if (id.isEmpty) continue;
      final name = _text(raw['name']);
      out.add(HubAgentReport(
        remoteAgentId: id,
        name: name.isEmpty ? id : name,
        avatar: _displayAvatar(_text(raw['avatar'])),
        engine: _text(raw['engine']),
        running: raw['running'] == true,
        workspaceUri: _workspace(raw),
        avatarBytes: _avatarBytes(_text(raw['avatar_data'])),
      ));
    }
    return out;
  }

  /// 主机写入名单并返回整本名册。客户端返回 null，不写盘。
  static Future<List<AgentRosterCard>?> applyIfHost({
    required Directory root,
    required String hubFingerprint,
    required List<Object?> agents,
  }) async {
    if (!await _isHost(root)) return null;
    final roster = AgentRosterStore(root);
    await roster.applyHubList(
      hubFingerprint: hubFingerprint,
      agents: reportsFromAgentList(agents),
    );
    return roster.load();
  }

  static String? cardIdFor(
    List<AgentRosterCard> cards,
    String hubFingerprint,
    String remoteAgentId,
  ) {
    final hub = hubFingerprint.trim();
    final remote = remoteAgentId.trim();
    if (hub.isEmpty || remote.isEmpty) return null;
    for (final card in cards) {
      if (card.boundToPouch) continue;
      if (card.hubFingerprint == hub && card.remoteAgentId == remote) {
        return card.id;
      }
    }
    return null;
  }

  /// 没有角色文件时视为主机，和回合交接点一样。
  static Future<void> applyAgentList({
    required Directory root,
    required String hubFingerprint,
    required List<Object?> agents,
  }) async {
    if (!await _isHost(root)) return;
    await AgentRosterStore(root).applyHubList(
      hubFingerprint: hubFingerprint,
      agents: reportsFromAgentList(agents),
    );
  }

  static Future<void> detachHub({
    required Directory root,
    required String hubFingerprint,
  }) async {
    if (!await _isHost(root)) return;
    await AgentRosterStore(root).detachHub(hubFingerprint);
  }

  static Future<bool> _isHost(Directory root) async {
    return (await PouchRoleStore(root).load()).isHost;
  }

  static String _text(Object? raw) => raw is String ? raw.trim() : '';

  static String _displayAvatar(String raw) {
    final s = raw;
    if (s.isEmpty || s.startsWith('/')) return '';
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(s)) return '';
    return s;
  }

  static String? _workspace(Map raw) {
    final a = raw['workspace_uri'];
    final b = raw['workspaceUri'];
    final s = a is String ? a : (b is String ? b : null);
    if (s == null || !s.startsWith('store://')) return null;
    return s;
  }

  static Uint8List? _avatarBytes(String data) {
    if (data.isEmpty) return null;
    try {
      final bytes = base64Decode(data);
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }
}

/// 这次能不能按名册拨到一台工人 Hub。
class PouchDialDecision {
  const PouchDialDecision._({
    required this.blocked,
    this.peerId,
    this.remoteAgentId,
  });

  /// 名册里还没有这张卡，调用方继续用原来的 peer id。
  const PouchDialDecision.absent() : this._(blocked: false);

  /// 卡还在，但拨号已清，或对不上任何已配对设备。
  const PouchDialDecision.blocked() : this._(blocked: true);

  const PouchDialDecision.dial({
    required String peerId,
    required String remoteAgentId,
  }) : this._(
          blocked: false,
          peerId: peerId,
          remoteAgentId: remoteAgentId,
        );

  final bool blocked;
  final String? peerId;
  final String? remoteAgentId;
}

/// 群编排和单聊在真正发出去之前问名册。客户端不拦。
class PouchRosterDial {
  PouchRosterDial._();

  static const blockedMessage = '这台工人 Hub 已卸掉，不能再拨';

  static PouchDialDecision decide({
    required List<AgentRosterCard> cards,
    required List<({String id, String fingerprint})> peers,
    required String hubFingerprint,
    required String remoteAgentId,
  }) {
    final hub = hubFingerprint.trim();
    final remote = remoteAgentId.trim();
    if (hub.isEmpty || remote.isEmpty) return const PouchDialDecision.absent();
    AgentRosterCard? card;
    for (final c in cards) {
      if (c.boundToPouch) continue;
      if (c.hubFingerprint == hub && c.remoteAgentId == remote) {
        card = c;
        break;
      }
    }
    if (card == null) return const PouchDialDecision.absent();
    if (!card.dialable) return const PouchDialDecision.blocked();
    for (final peer in peers) {
      final id = peer.id.trim();
      if (peer.fingerprint.trim() == hub && id.isNotEmpty) {
        return PouchDialDecision.dial(peerId: id, remoteAgentId: remote);
      }
    }
    return const PouchDialDecision.blocked();
  }

  /// 读不到名册或还不是主机时当作没有这张卡，不打断原来的拨号。
  static Future<PouchDialDecision> decideLive({
    required String fallbackPeerId,
    required String remoteAgentId,
    String? hubFingerprint,
    Directory? root,
    Future<PairedPeer?> Function(String id)? peerById,
    Future<List<PairedPeer>> Function()? loadPeers,
  }) async {
    try {
      final storeRoot = root ?? await StoreService.instance.storeRoot();
      if (!(await PouchRoleStore(storeRoot).load()).isHost) {
        return const PouchDialDecision.absent();
      }
      final peer = await (peerById ?? PeerStorageService().getPeerById)(
        fallbackPeerId,
      );
      var fingerprint = peer?.fingerprint.trim() ?? '';
      if (fingerprint.isEmpty) fingerprint = hubFingerprint?.trim() ?? '';
      if (fingerprint.isEmpty) return const PouchDialDecision.absent();
      final listed = await (loadPeers ?? PeerStorageService().loadAllPeers)();
      return decide(
        cards: await AgentRosterStore(storeRoot).load(),
        peers: [
          for (final item in listed) (id: item.id, fingerprint: item.fingerprint),
        ],
        hubFingerprint: fingerprint,
        remoteAgentId: remoteAgentId,
      );
    } catch (_) {
      return const PouchDialDecision.absent();
    }
  }
}
