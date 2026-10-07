import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../models/channel.dart';
import '../../service_locator.dart';
import '../../services/chat_service.dart';
import '../../services/group/group_member_session_service.dart';
import '../../services/local_database_service.dart';
import '../../services/local_user_identity.dart';
import '../../services/logger_service.dart';
import '../../storage/pouch_session.dart';
import '../hub_group_cache.dart';
import 'hub_event_client.dart';
import 'peer_connection_manager.dart';

/// 一次群改动的结果。群定义以主机返回的 JSON 为准。
class GroupCommit {
  const GroupCommit({required this.ok, this.error, this.group});

  final bool ok;
  final String? error;
  final Map<String, dynamic>? group;

  String? get groupId {
    final id = group?['id'];
    if (id is String && id.isNotEmpty) return id;
    final deleted = group?['deleted_id'];
    if (deleted is String && deleted.isNotEmpty) return deleted;
    return null;
  }

  factory GroupCommit.failure(String error) =>
      GroupCommit(ok: false, error: error);

  factory GroupCommit.success([Map<String, dynamic>? group]) =>
      GroupCommit(ok: true, group: group);
}

/// 群的写入口。生产走 [HubGroupRegistry]，测试可以换一份。
abstract class GroupMutations {
  Future<GroupCommit> commit(String op, Map<String, dynamic> fields);
}

/// 本地群表是主机群注册表的缓存。
///
/// 首次连上和事件重置时拉全量；平时靠 `groups.changed`。写操作发
/// `group_mutate_req`，落库以返回值和随后的事件为准。
class HubGroupRegistry implements GroupMutations {
  HubGroupRegistry({
    this.send,
    Stream<PeerControlEvent>? events,
    this.db,
    this.notify,
  }) : events = events ?? PeerConnectionManager.instance.controlEvents;

  final Future<bool> Function(String peerId, Map<String, dynamic> frame)? send;
  final Stream<PeerControlEvent> events;
  final LocalDatabaseService? db;
  final void Function(String channelId)? notify;

  final _uuid = const Uuid();
  final _log = LoggerService();
  StreamSubscription<HubNotice>? _noticeSub;

  void start() {
    if (!getIt.isRegistered<HubEventClient>()) return;
    _noticeSub ??= getIt<HubEventClient>().notices.listen((notice) {
      if (notice.event.kind != 'groups.changed') return;
      unawaited(applyEvent(notice.event.data));
    });
  }

  Future<void> dispose() async {
    await _noticeSub?.cancel();
    _noticeSub = null;
  }

  /// 用主机上的全量群替换本地群缓存。
  Future<void> refresh(String peerId) async {
    final listed = await _request(peerId, {'type': 'group_list_req'});
    if (listed == null) return;
    final raw = listed['groups'];
    if (raw is! List) return;
    final groups = <Map<String, dynamic>>[
      for (final item in raw)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
    final database = _database;
    if (database == null) return;
    final local = await database.getAllChannels();
    final localIds = [
      for (final channel in local)
        if (channel.isGroup) channel.id,
    ];
    for (final id in staleGroupIds(localIds, groups)) {
      await _drop(database, id);
    }
    for (final group in groups) {
      await _upsert(database, channelFromHubGroup(group));
    }
  }

  Future<void> applyEvent(Map<String, dynamic> data) async {
    final database = _database;
    if (database == null) return;
    final deleted = data['deleted_id'];
    if (deleted is String && deleted.isNotEmpty) {
      await _drop(database, deleted);
      return;
    }
    final group = data['group'];
    if (group is Map) {
      await _upsert(database, channelFromHubGroup(Map<String, dynamic>.from(group)));
    }
  }

  @override
  Future<GroupCommit> commit(String op, Map<String, dynamic> fields) async {
    final session = await PouchSessionStore.readActive();
    final peerId = session?.hostPeerId ?? '';
    if (peerId.isEmpty) {
      return GroupCommit.failure('没有连上主机');
    }
    final requestId = _uuid.v4();
    final frame = <String, dynamic>{
      'type': 'group_mutate_req',
      'request_id': requestId,
      'op': op,
      for (final entry in fields.entries)
        if (entry.key != 'preview') entry.key: entry.value,
    };
    final response = await _request(peerId, frame, responseType: 'group_mutate_resp');
    if (response == null) {
      return GroupCommit.failure('主机没有回应');
    }
    if (response['ok'] != true) {
      return GroupCommit.failure(response['error']?.toString() ?? '改群失败');
    }
    final group = response['group'];
    if (group is Map) {
      final body = Map<String, dynamic>.from(group);
      final database = _database;
      if (database != null) {
        if (body['deleted_id'] is String) {
          await _drop(database, body['deleted_id'] as String);
        } else if (body['id'] is String) {
          await _upsert(database, channelFromHubGroup(body));
        }
      }
      return GroupCommit.success(body);
    }
    return GroupCommit.success();
  }

  LocalDatabaseService? get _database {
    if (db != null) return db;
    if (getIt.isRegistered<LocalDatabaseService>()) {
      return getIt<LocalDatabaseService>();
    }
    return null;
  }

  Future<void> _upsert(LocalDatabaseService database, Channel channel) async {
    final existing = await database.getChannelById(channel.id);
    if (existing == null) {
      await database.createChannel(channel, channel.createdBy);
    } else {
      await database.updateChannel(channel.copyWith(
        sourceGroupChannelId:
            channel.sourceGroupChannelId ?? existing.sourceGroupChannelId,
        sourceSheChannelId:
            channel.sourceSheChannelId ?? existing.sourceSheChannelId,
      ));
      final previous = await database.getChannelMemberIds(channel.id);
      for (final id in previous) {
        await database.removeChannelMember(channel.id, id);
      }
      for (final member in channel.members) {
        await database.addChannelMember(
          channel.id,
          member.id,
          role: member.role,
          groupBio: member.groupBio,
        );
      }
    }
    await GroupMemberSessionService(database).ensureMemberSessionsForGroup(
      groupChannel: channel,
      userId: LocalUserIdentity.id,
    );
    _notify(channel.id);
  }

  Future<void> _drop(LocalDatabaseService database, String id) async {
    await GroupMemberSessionService(database)
        .deleteMemberSessionsForGroupChannel(id);
    final members = await database.getChannelMemberIds(id);
    for (final member in members) {
      await database.removeChannelMember(id, member);
    }
    await database.deleteChannelMessages(id);
    await database.deleteChannel(id);
    _notify(id);
  }

  void _notify(String channelId) {
    final hook = notify;
    if (hook != null) {
      hook(channelId);
      return;
    }
    if (getIt.isRegistered<ChatService>()) {
      getIt<ChatService>().notifyChannelUpdate(channelId);
    }
  }

  Future<Map<String, dynamic>?> _request(
    String peerId,
    Map<String, dynamic> frame, {
    String responseType = 'group_list_resp',
  }) async {
    final requestId = frame['request_id'] as String? ?? _uuid.v4();
    frame['request_id'] = requestId;
    final done = Completer<Map<String, dynamic>?>();
    final sub = events.listen((event) {
      if (done.isCompleted) return;
      if (event.peerId != peerId || event.type != responseType) return;
      if (event.data['request_id'] != requestId) return;
      done.complete(event.data);
    });
    try {
      final sent = await _send(peerId, frame);
      if (!sent) return null;
      return await done.future.timeout(const Duration(seconds: 8));
    } catch (error) {
      _log.warning('group request failed: $error', tag: 'HubGroup');
      return null;
    } finally {
      await sub.cancel();
    }
  }

  Future<bool> _send(String peerId, Map<String, dynamic> frame) {
    final send = this.send;
    if (send != null) return send(peerId, frame);
    return PeerConnectionManager.instance.sendControl(peerId, frame);
  }
}

/// 测试里用本地预览代替主机回包，把 [GroupCommit] 写进数据库。
class EchoGroupMutations implements GroupMutations {
  EchoGroupMutations(this.db);

  final LocalDatabaseService db;

  @override
  Future<GroupCommit> commit(String op, Map<String, dynamic> fields) async {
    final preview = fields['preview'];
    if (preview is! Map) {
      return GroupCommit.failure('no preview');
    }
    final channel = Channel.fromJson(Map<String, dynamic>.from(preview));
    final existing = await db.getChannelById(channel.id);
    if (existing == null) {
      await db.createChannel(channel, LocalUserIdentity.id);
    } else {
      await db.updateChannel(channel);
    }
    return GroupCommit.success(channel.toJson());
  }
}
