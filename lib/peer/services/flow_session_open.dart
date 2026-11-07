import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../models/channel.dart';
import '../../peer/models/flow_models.dart';
import '../../service_locator.dart' show getIt;
import '../../services/chat_navigation_service.dart';
import '../../services/local_database_service.dart';
import '../../services/she_service.dart' show SheService;
import '../../utils/session_utils.dart';
import 'peer_agent_client_service.dart'
    show
        kSyncedPeerSessionPrefix,
        remoteSessionIdFromChannelId,
        syncedPeerChannelId;
import 'peer_agent_ids.dart';

/// 折叠组 / 运行视图里的 session id 能不能当主机会话 id 用。
///
/// P4 之后节点会话是 `flow_<rid8>_<node>`（无冒号），折叠项里存的就是它，
/// 可以直接拼 `psess_`。旧运行 / 群运行的条目可能仍是引擎槽位 key
/// （`flow:<rid>:<node>` / `group:<gid>:<sid>:...`），那种拼不出真频道，
/// 点击只能继续走运行视图。
///
/// 参与条目（`part-flow-<run>-<node>`）是折叠组 / 搜索为了展示列出来的
/// 成员行，不是会话 —— 它同样没有冒号，以前会被当成真会话拼出
/// `psess_part-flow-…` 这种空频道，还挡住了真正的运行页入口。真会话必须
/// 以 `flow_` 开头。
String? flowFoldedSessionId(String raw) {
  final id = raw.trim();
  if (id.isEmpty || id.contains(':') || id.contains('/')) return null;
  if (id.startsWith(kSyncedPeerSessionPrefix)) return null;
  if (id.startsWith('part-')) return null;
  if (!id.startsWith('flow_')) return null;
  return id;
}

/// 测试里替换真正的导航动作，用来核对拼出来的频道 id / agent id。
@visibleForTesting
Future<void> Function(String channelId, String? agentId)?
    debugOpenFlowSessionChannel;

/// P6 测试用：记录「去回答」带上的高亮消息 id；每次打开会话都会重置。
@visibleForTesting
String? debugLastFlowSessionHighlightMessageId;

/// 节点会话在本机的频道 id。主机用 `psess_<sessionId>` 广播 `message.created`、
/// `agent_chunk` 和 `session.state`，App 打开的是同一个壳。
String flowSessionChannelId(String sessionId) =>
    syncedPeerChannelId(sessionId.trim());

/// 本机 agent 行 id：Hub 的 agent id 就是行 id，但存量行还可能是
/// `peeragent_<peer>_<remote>`，两种都要认。找不到就退回 Hub id 本身。
Future<String> resolveFlowAgentLocalId({
  required String peerId,
  required String remoteAgentId,
  LocalDatabaseService? db,
}) async {
  final fallback = peerAgentLocalId(peerId, remoteAgentId);
  if (remoteAgentId.isEmpty) return fallback;
  LocalDatabaseService? database = db;
  if (database == null && getIt.isRegistered<LocalDatabaseService>()) {
    database = getIt<LocalDatabaseService>();
  }
  if (database == null) return fallback;
  try {
    final agents = await database.getAllRemoteAgents();
    for (final agent in agents) {
      if (isPeerAgentRowId(agent.id, peerId, remoteAgentId)) return agent.id;
      final rid = agent.remoteAgentId;
      final source = agent.sourcePeerId;
      if (rid == remoteAgentId && (source == null || source == peerId)) {
        return agent.id;
      }
    }
  } catch (_) {
    // 数据库还没就绪不该挡住打开会话。
  }
  return fallback;
}

/// 建壳 / 补成员 / 改名的**唯一实现**（A9-8）。
///
/// 两条路径共用它：Hub 的 `message.created` /
/// `agent_chunk`（[PeerAgentClientService.prepareLocalTargetForHubMessage]），
/// 以及卡片 / 折叠项先到的 P4 频道壳（[ensureFlowSessionShell]）。以前两份
/// 各写一遍，卡片那条直接用卡面问题当标题（`[implicit]` 标记会混进会话
/// 名），也永远不会因为后续带 `session_title` 的消息而改名。
///
/// 标题一律过 [SessionUtils.cleanClaudeSessionTitle]：清不干净就回落
/// 'Session'。已存在的壳在有干净标题时改回主机给的标题（flow 壳，或还停在
/// 默认 'Session' 的壳），普通用户改过名的会话不动。
Future<void> ensureLocalSessionShell({
  required LocalDatabaseService db,
  required String channelId,
  required String agentId,
  required String? sessionTitle,
}) async {
  if (channelId.isEmpty) return;
  final clean = SessionUtils.cleanClaudeSessionTitle(sessionTitle);
  final existing = await db.getChannelById(channelId);
  if (existing == null) {
    // 没有 agent 可当成员时不要建一个只有 user 的空频道：主机名单还没
    // 同步过来的空 agentId 会拼出 `['user', '']` 这种脏成员。
    if (agentId.isEmpty) return;
    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: clean ?? 'Session',
        type: 'dm',
        memberIds: ['user', agentId],
        isPrivate: true,
      ),
      'user',
    );
    return;
  }
  final members = await db.getChannelMemberIds(channelId);
  if (!members.contains('user')) {
    await db.addChannelMember(channelId, 'user');
  }
  if (agentId.isNotEmpty && !members.contains(agentId)) {
    await db.addChannelMember(channelId, agentId);
  }
  final bare = remoteSessionIdFromChannelId(channelId) ?? channelId;
  final isFlowShell = bare.startsWith('flow_');
  if (clean != null &&
      clean != existing.name &&
      (isFlowShell || existing.name.isEmpty || existing.name == 'Session')) {
    await db.updateChannelName(channelId, clean);
  }
}

/// 频道还没被 `message.created` 同步下来时，先在本机建一个空壳。
///
/// `ChatNavigationService._resolveSelection` 在频道不存在时会试
/// `syncedPeerChannelId(channelId)`；对于本来就是 `psess_<id>` 的频道那是
/// `psess_psess_<id>`，必然查不到。壳建好之后 ChatScreen 的成员、标题、
/// 发送目标都齐了，主机随后同步下来的消息会落到同一个频道上。
Future<void> ensureFlowSessionShell({
  required String channelId,
  required String agentId,
  required String title,
  LocalDatabaseService? db,
}) async {
  LocalDatabaseService? database = db;
  if (database == null && getIt.isRegistered<LocalDatabaseService>()) {
    database = getIt<LocalDatabaseService>();
  }
  if (database == null) return;
  try {
    await ensureLocalSessionShell(
      db: database,
      channelId: channelId,
      agentId: agentId,
      sessionTitle: title,
    );
  } catch (_) {
    // 建壳失败也要让导航继续：ChatScreen 对未落库的频道有兜底路径。
  }
}

/// 打开一条工作流会话：P4 的节点会话、P6 的运行级惜宝会话、以及「去回答」
/// 定位到待答卡片，都走这同一条路。
///
/// [remoteAgentId] 是 Hub 侧 agent id；为空时仍会打开频道，只是标题栏少了
/// agent 名字。主机刚建好会话、名单还没同步过来时也能点开。
/// [highlightMessageId] 交给 [ChatNavigationService.openChannel] 定位到那条
/// 确定性表单行（`peer_form_<approval_id>`）。
Future<void> openFlowSession({
  required String peerId,
  required String sessionId,
  String remoteAgentId = '',
  String title = '',
  String? highlightMessageId,
  LocalDatabaseService? db,
}) async {
  final trimmed = sessionId.trim();
  if (trimmed.isEmpty) return;
  final channelId = flowSessionChannelId(trimmed);
  final localAgentId = await resolveFlowAgentLocalId(
    peerId: peerId,
    remoteAgentId: remoteAgentId,
    db: db,
  );
  await ensureFlowSessionShell(
    channelId: channelId,
    agentId: localAgentId,
    title: title,
    db: db,
  );
  debugLastFlowSessionHighlightMessageId = highlightMessageId;
  final hook = debugOpenFlowSessionChannel;
  if (hook != null) {
    await hook(channelId, localAgentId);
    return;
  }
  await ChatNavigationService.instance.openChannel(
    channelId: channelId,
    agentId: localAgentId,
    messageId: highlightMessageId,
  );
}

/// 把一个工作流节点会话当作普通私聊打开（P4）。
Future<void> openFlowNodeSession({
  required String peerId,
  required String sessionId,
  required String remoteAgentId,
  String title = '',
  LocalDatabaseService? db,
}) =>
    openFlowSession(
      peerId: peerId,
      sessionId: sessionId,
      remoteAgentId: remoteAgentId,
      title: title,
      db: db,
    );

/// 顶部「运行会话」该打开的那条私聊。
///
/// 节点上配的 agent 才是干活的人，聊天记录在它自己的节点会话里
/// （`flow_<tag>_<node>`）。design 配的不是惜宝时，不能再进
/// `flow_<tag>_she` 那条惜宝私聊。按树的先序取第一个已经有真会话、
/// 也有 agent 的节点。一个都没有（节点还没跑）才退回运行级惜宝会话。
({String sessionId, String agentId})? flowRunConversationTarget(
  List<FlowNode> tree, {
  String? sheSessionId,
}) {
  for (final root in tree) {
    final node = root.find((candidate) {
      final sessionId = flowFoldedSessionId(candidate.sessionId ?? '');
      final agentId = (candidate.agentId ?? '').trim();
      return sessionId != null && agentId.isNotEmpty;
    });
    if (node == null) continue;
    return (
      sessionId: flowFoldedSessionId(node.sessionId!)!,
      agentId: node.agentId!.trim(),
    );
  }
  final she = sheSessionId?.trim() ?? '';
  if (she.isEmpty) return null;
  return (sessionId: she, agentId: SheService.sheId);
}

/// P6：节点还没跑出自己的会话时，顶部「运行会话」才打开惜宝会话
/// （`flow_<rid8>_she`）。
Future<void> openFlowRunSession({
  required String peerId,
  required String runSheSessionId,
  String title = '',
  LocalDatabaseService? db,
}) =>
    openFlowSession(
      peerId: peerId,
      sessionId: runSheSessionId,
      remoteAgentId: SheService.sheId,
      title: title,
      db: db,
    );
