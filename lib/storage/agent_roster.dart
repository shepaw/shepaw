import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// 名册上可拨号的那一截。卸掉设备后整段清空，展示信息仍留在卡上。
class AgentDial {
  const AgentDial({
    required this.running,
    this.workspaceUri,
  });

  final bool running;
  final String? workspaceUri;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'running': running,
        if (workspaceUri != null && workspaceUri!.isNotEmpty)
          'workspace_uri': workspaceUri,
      };

  static AgentDial? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final uri = raw['workspace_uri'] as String?;
    return AgentDial(
      running: raw['running'] == true,
      workspaceUri: (uri == null || uri.isEmpty) ? null : uri,
    );
  }
}

/// 储物袋里的一张 Agent 卡。
///
/// [hubFingerprint] 与 [remoteAgentId] 在卸掉之后仍保留，方便同一台
/// 工人 Hub 上的同一个 Agent 再连上来时对上原卡。
/// [boundToPouch] 的卡（惜宝）没有拨号信息。
class AgentRosterCard {
  const AgentRosterCard({
    required this.id,
    required this.name,
    required this.avatar,
    required this.engine,
    this.hubFingerprint,
    this.remoteAgentId,
    this.boundToPouch = false,
    this.dial,
    this.avatarFile,
  });

  final String id;
  final String name;
  final String avatar;
  final String engine;
  final String? hubFingerprint;
  final String? remoteAgentId;
  final bool boundToPouch;
  final AgentDial? dial;

  /// `.system/` 下的相对路径。没有单独头像文件时为 null。
  final String? avatarFile;

  bool get dialable => !boundToPouch && dial != null;

  AgentRosterCard copyWith({
    String? name,
    String? avatar,
    String? engine,
    String? hubFingerprint,
    String? remoteAgentId,
    bool? boundToPouch,
    AgentDial? dial,
    bool clearDial = false,
    String? avatarFile,
    bool clearAvatarFile = false,
  }) {
    return AgentRosterCard(
      id: id,
      name: name ?? this.name,
      avatar: avatar ?? this.avatar,
      engine: engine ?? this.engine,
      hubFingerprint: hubFingerprint ?? this.hubFingerprint,
      remoteAgentId: remoteAgentId ?? this.remoteAgentId,
      boundToPouch: boundToPouch ?? this.boundToPouch,
      dial: clearDial ? null : (dial ?? this.dial),
      avatarFile: clearAvatarFile ? null : (avatarFile ?? this.avatarFile),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'avatar': avatar,
        'engine': engine,
        if (hubFingerprint != null) 'hub_fingerprint': hubFingerprint,
        if (remoteAgentId != null) 'remote_agent_id': remoteAgentId,
        if (boundToPouch) 'bound_to_pouch': true,
        if (dial != null) 'dial': dial!.toJson(),
        if (avatarFile != null) 'avatar_file': avatarFile,
      };

  static AgentRosterCard? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim() ?? '';
    final name = (json['name'] as String?)?.trim() ?? '';
    if (id.isEmpty || name.isEmpty) return null;
    return AgentRosterCard(
      id: id,
      name: name,
      avatar: json['avatar'] as String? ?? '',
      engine: json['engine'] as String? ?? '',
      hubFingerprint: _nonEmpty(json['hub_fingerprint'] as String?),
      remoteAgentId: _nonEmpty(json['remote_agent_id'] as String?),
      boundToPouch: json['bound_to_pouch'] == true,
      dial: AgentDial.fromJson(json['dial']),
      avatarFile: _nonEmpty(json['avatar_file'] as String?),
    );
  }

  static String? _nonEmpty(String? raw) {
    final s = raw?.trim() ?? '';
    return s.isEmpty ? null : s;
  }
}

/// 一台工人 Hub 这次报上来的一个 Agent。
class HubAgentReport {
  const HubAgentReport({
    required this.remoteAgentId,
    required this.name,
    this.avatar = '',
    this.engine = '',
    this.running = false,
    this.workspaceUri,
    this.avatarBytes,
  });

  final String remoteAgentId;
  final String name;
  final String avatar;
  final String engine;
  final bool running;
  final String? workspaceUri;
  final Uint8List? avatarBytes;
}

/// `.system/agent_roster.json`。群编排只读 [dialable]，历史展示读整本。
class AgentRosterStore {
  AgentRosterStore(
    this.root, {
    String Function()? newId,
  }) : _newId = newId ?? (() => const Uuid().v4());

  final Directory root;
  final String Function() _newId;

  static const fileName = 'agent_roster.json';

  File get _file => File(p.join(root.path, '.system', fileName));

  Future<List<AgentRosterCard>> load() async {
    if (!await _file.exists()) return const [];
    final decoded = jsonDecode(await _file.readAsString());
    if (decoded is! Map) {
      throw const FormatException('agent roster root must be an object');
    }
    final raw = decoded['cards'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          if (AgentRosterCard.fromJson(item.cast<String, dynamic>())
              case final card?)
            card,
    ];
  }

  /// 当前还能拨出去的卡。惜宝和已卸掉拨号的卡不在里面。
  Future<List<AgentRosterCard>> dialable() async {
    final cards = await load();
    return [for (final c in cards) if (c.dialable) c];
  }

  Future<AgentRosterCard?> findById(String id) async {
    final cards = await load();
    for (final c in cards) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 袋子自己的 Agent（惜宝）。已有同 id 的卡则原样返回，不覆盖后来改过的名字。
  Future<AgentRosterCard> ensurePouchBound({
    required String id,
    required String name,
    String avatar = '',
    String engine = '',
  }) async {
    final cards = await load();
    for (final c in cards) {
      if (c.id == id) return c;
    }
    final card = AgentRosterCard(
      id: id,
      name: name,
      avatar: avatar,
      engine: engine,
      boundToPouch: true,
    );
    await _save([...cards, card]);
    return card;
  }

  /// 工人 Hub 上报一个 Agent。同一指纹 + 远端 id 对上原卡，只把拨号填回去。
  Future<AgentRosterCard> upsertWorker({
    required String hubFingerprint,
    required String remoteAgentId,
    required String name,
    String avatar = '',
    String engine = '',
    bool running = false,
    String? workspaceUri,
    Uint8List? avatarBytes,
  }) async {
    final hub = hubFingerprint.trim();
    final remote = remoteAgentId.trim();
    if (hub.isEmpty || remote.isEmpty) {
      throw ArgumentError('hubFingerprint and remoteAgentId are required');
    }
    final cards = [...await load()];
    final index = cards.indexWhere(
      (c) =>
          !c.boundToPouch &&
          c.hubFingerprint == hub &&
          c.remoteAgentId == remote,
    );
    final dial = AgentDial(running: running, workspaceUri: workspaceUri);
    if (index >= 0) {
      var card = cards[index].copyWith(
        name: name,
        avatar: avatar,
        engine: engine,
        dial: dial,
      );
      if (avatarBytes != null) {
        card = await _writeAvatar(card, avatarBytes);
      }
      cards[index] = card;
      await _save(cards);
      return card;
    }
    var card = AgentRosterCard(
      id: _newId(),
      name: name,
      avatar: avatar,
      engine: engine,
      hubFingerprint: hub,
      remoteAgentId: remote,
      dial: dial,
    );
    if (avatarBytes != null) {
      card = await _writeAvatar(card, avatarBytes);
    }
    cards.add(card);
    await _save(cards);
    return card;
  }

  /// 用这台工人 Hub 刚报上来的整份名单刷新拨号。
  ///
  /// 名单里有的对上原卡；没有的只清拨号，展示信息留下。一次写盘。
  Future<void> applyHubList({
    required String hubFingerprint,
    required List<HubAgentReport> agents,
  }) async {
    final hub = hubFingerprint.trim();
    if (hub.isEmpty) return;
    final cards = [...await load()];
    final seen = <String>{};
    for (final report in agents) {
      final remote = report.remoteAgentId.trim();
      final name = report.name.trim();
      if (remote.isEmpty || name.isEmpty || !seen.add(remote)) continue;
      final dial = AgentDial(
        running: report.running,
        workspaceUri: report.workspaceUri,
      );
      final index = cards.indexWhere(
        (c) =>
            !c.boundToPouch &&
            c.hubFingerprint == hub &&
            c.remoteAgentId == remote,
      );
      if (index >= 0) {
        var card = cards[index].copyWith(
          name: name,
          avatar: report.avatar,
          engine: report.engine,
          dial: dial,
        );
        final bytes = report.avatarBytes;
        if (bytes != null && bytes.isNotEmpty) {
          card = await _writeAvatar(card, bytes);
        }
        cards[index] = card;
        continue;
      }
      var card = AgentRosterCard(
        id: _newId(),
        name: name,
        avatar: report.avatar,
        engine: report.engine,
        hubFingerprint: hub,
        remoteAgentId: remote,
        dial: dial,
      );
      final bytes = report.avatarBytes;
      if (bytes != null && bytes.isNotEmpty) {
        card = await _writeAvatar(card, bytes);
      }
      cards.add(card);
    }
    final synced = [
      for (final c in cards)
        if (!c.boundToPouch &&
            c.hubFingerprint == hub &&
            !seen.contains(c.remoteAgentId))
          c.copyWith(clearDial: true)
        else
          c,
    ];
    await _save(synced);
  }

  /// 卸掉一台工人 Hub：清掉它名下卡的拨号，卡本身留下。
  Future<void> detachHub(String hubFingerprint) async {
    final hub = hubFingerprint.trim();
    if (hub.isEmpty) return;
    final cards = [
      for (final c in await load())
        if (!c.boundToPouch && c.hubFingerprint == hub)
          c.copyWith(clearDial: true)
        else
          c,
    ];
    await _save(cards);
  }

  Future<Uint8List?> readAvatar(AgentRosterCard card) async {
    final rel = card.avatarFile;
    if (rel == null) return null;
    final file = File(p.join(root.path, '.system', rel));
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  Future<void> _save(List<AgentRosterCard> cards) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'v': 1,
      'cards': [for (final c in cards) c.toJson()],
    }));
  }

  Future<AgentRosterCard> _writeAvatar(
    AgentRosterCard card,
    Uint8List bytes,
  ) async {
    final rel = p.join('agent_roster_avatars', card.id);
    final file = File(p.join(root.path, '.system', rel));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return card.copyWith(avatarFile: rel);
  }
}
