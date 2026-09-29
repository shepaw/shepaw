import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../storage/agent_roster.dart';
import '../storage/pouch_role.dart';

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
