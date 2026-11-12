import 'dart:async';

import 'package:flutter/material.dart';

import '../models/conversation_selection.dart';
import '../l10n/app_localizations.dart';
import '../onboarding/phone_host_store.dart';
import '../peer/services/peer_agent_client_service.dart'
    show syncedPeerChannelId;
import '../screens/chat_screen.dart';
import '../service_locator.dart';
import '../storage/pouch_session.dart';
import '../utils/platform_utils.dart';
import 'chat_service.dart';
import 'composer_draft_service.dart';
import 'local_database_service.dart';
import 'local_user_identity.dart';
import 'app_lifecycle_service.dart';
import 'logger_service.dart';
import 'route_gate.dart';
import 'session/activated_session_recorder.dart';
import 'session/last_activated_session_store.dart';

/// 深链 / 通知点进来时，没有有效登录态该停在哪一页；`null` 表示可以继续。
///
/// 手机没有本机密码，回主机登录页；还没配过主机就先配对。桌面回储物袋
/// 登录页，它自己会区分本机 / 远端主机。
///
/// [onLoginGate] 为真时即便 token 还有效也不放行：用户这次会话还没过登录页，
/// 不能靠通知 / 审核条把登录页绕过去。
String? deepLinkLoginRoute({
  required bool isDesktop,
  required bool loggedIn,
  required bool onLoginGate,
  required String? phoneHostId,
}) {
  if (loggedIn && !onLoginGate) return null;
  if (isDesktop) return '/pouch';
  final host = phoneHostId?.trim() ?? '';
  return host.isEmpty ? '/remote-connect' : '/phone-login';
}

/// Opens a chat session from notifications / global banner (mobile + desktop).
class ChatNavigationService {
  ChatNavigationService._();
  static final ChatNavigationService instance = ChatNavigationService._();

  /// 根 Navigator 当前的 context。没有 UI 的地方（通知、定时任务）偶尔要
  /// 借它取一次 l10n，拿不到时返回 null，调用方退回兜底文案。
  BuildContext? get navigatorContext => _navigatorKey?.currentContext;

  AppLocalizations? get l10nOrNull {
    final ctx = navigatorContext;
    return ctx == null ? null : AppLocalizations.of(ctx);
  }

  static const _tag = 'ChatNav';

  GlobalKey<NavigatorState>? _navigatorKey;

  /// Desktop split-panel registers this to select a conversation in-place.
  void Function(ConversationSelection selection)? _desktopHandler;

  void init({GlobalKey<NavigatorState>? navigatorKey}) {
    _navigatorKey = navigatorKey ??
        (getIt.isRegistered<GlobalKey<NavigatorState>>()
            ? getIt<GlobalKey<NavigatorState>>()
            : null);
  }

  /// Called from [DesktopHomeScreen] so deep links update the right panel.
  void setDesktopHandler(
    void Function(ConversationSelection selection)? handler,
  ) {
    _desktopHandler = handler;
  }

  /// Open [channelId], optionally scrolling to [messageId].
  ///
  /// [recordActivation] 默认开：通知、审核条、流程节点、玉简来源会话都是
  /// 用户点进一条明确的会话。按活跃时间 / 生成 id 兜底出来的频道（例如
  /// [openAgentConversation]）不是人工点选，必须显式传 false，否则会把一条
  /// 有效指针钉死。
  Future<void> openChannel({
    required String channelId,
    String? messageId,
    String? agentId,
    String? agentName,
    String? agentAvatar,
    bool recordActivation = true,
  }) async {
    // 深链不经过登录页，必须自己补上登录校验。否则冷启动落在登录页时，
    // 审核条 / 通知仍能把人直接推进聊天。
    final session = await PouchSessionStore.readActive();
    final now = DateTime.now().millisecondsSinceEpoch;
    final loggedIn = session != null && session.isLoggedIn(now);
    final onDesktop = isDesktopPlatform;
    final loginRoute = deepLinkLoginRoute(
      isDesktop: onDesktop,
      loggedIn: loggedIn,
      onLoginGate: RouteGateObserver.onGate.value,
      phoneHostId: onDesktop ? null : await PhoneHostStore.read(),
    );
    if (loginRoute != null) {
      final nav = _navigatorKey?.currentState;
      if (nav == null) {
        LoggerService().warning(
          'Not logged in and no navigator; dropping deep link $channelId',
          tag: _tag,
        );
        return;
      }
      nav.pushNamedAndRemoveUntil(loginRoute, (_) => false);
      return;
    }

    final selection = await _resolveSelection(
      channelId: channelId,
      messageId: messageId,
      agentId: agentId,
      agentName: agentName,
      agentAvatar: agentAvatar,
    );

    // 通知 / 审核条 / 流程节点点进的是一条明确的会话，算人工激活。只有真的
    // 会把人送进这个会话时才写：登录门 / 没有 navigator 的丢弃分支不能覆盖
    // 掉一条本来有效的指针。群会话按 channels.updated_at 恢复，不改指针。
    void recordIfNeeded() {
      if (!recordActivation) return;
      final targetAgentId = selection.agentId;
      final targetChannelId = selection.channelId;
      if (targetAgentId == null ||
          targetAgentId.isEmpty ||
          selection.groupFamilyId != null ||
          targetChannelId == null ||
          targetChannelId.isEmpty) {
        return;
      }
      // 校验频道确实是这个 agent 的普通 DM：群成员中转 / She 中转不是 agent
      // 行的落点，写进去会把上一次真正点开的会话冲掉。
      unawaited(rememberActivatedDmChannel(
        targetChannelId,
        agentId: targetAgentId,
      ));
    }

    final desktop = _desktopHandler;
    if (desktop != null) {
      recordIfNeeded();
      desktop(selection);
      return;
    }

    final nav = _navigatorKey?.currentState;
    if (nav == null) {
      LoggerService()
          .warning('No navigator to open channel $channelId', tag: _tag);
      return;
    }
    recordIfNeeded();
    // 已经在看这个会话（聊天页 → 详情 → 「发起对话」）：退回那一页，不再叠一层。
    // activeChannelId 只在 ChatScreen 挂载期间有值，所以命中就说明它在栈里。
    if (AppLifecycleService().activeChannelId == selection.channelId &&
        nav.canPop()) {
      nav.maybePop();
      return;
    }
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          agentId: selection.agentId,
          agentName: selection.agentName,
          agentAvatar: selection.agentAvatar,
          channelId: selection.channelId,
          highlightMessageId: selection.highlightMessageId,
          showBackButton: true,
        ),
      ),
    );
  }

  /// 打开和某个 Agent 的会话：接着最近一次会话，没有就新开一个。
  ///
  /// 通讯录、Agent 详情、设备详情共用这一条，不要各自 `push(ChatScreen)`——
  /// 那样会绕过登录校验和桌面端的右栏接线，还会丢掉已有会话。
  Future<void> openAgentConversation({
    required String agentId,
    required String agentName,
    String? agentAvatar,
  }) async {
    final chatService = getIt<ChatService>();
    const userId = LocalUserIdentity.id;
    var channelId =
        await chatService.getLatestActiveChannelId(userId, agentId) ??
            chatService.generateChannelId(userId, agentId);
    // 「接着最近一次会话」也认人工点开的指针：主机同步会覆写 updated_at，
    // 光看活跃时间未必是用户上次实际打开的那条。
    final store = getIt.isRegistered<LastActivatedSessionStore>()
        ? getIt<LastActivatedSessionStore>()
        : null;
    final remembered =
        await store?.read(LastActivatedSessionStore.agentKey(agentId));
    if (remembered != null && remembered.isNotEmpty) {
      final db = getIt.isRegistered<LocalDatabaseService>()
          ? getIt<LocalDatabaseService>()
          : LocalDatabaseService();
      final activated = await resolveRememberedAgentChannel(
        db: db,
        agentId: agentId,
        remembered: remembered,
      );
      if (activated != null) channelId = activated;
    }
    await openChannel(
      channelId: channelId,
      agentId: agentId,
      agentName: agentName,
      agentAvatar: agentAvatar,
      // 这里的 channelId 可能是活跃时间兜底出来的，用户并没有挑过会话。
      recordActivation: false,
    );
  }

  /// 人工激活指针能不能作为这个 agent 的「接着聊」落点。
  ///
  /// 与会话列表入口同口径（`ConversationListController._loadAgentPreviews`）：
  /// 必须是这个 agent 名下、还在库里的普通 DM 会话，而且「保留下来了」（有
  /// 落库消息或还有未发送草稿）。群会话 / 群成员中转 / She 中转 / 空壳 /
  /// 已被删掉的会话一律返回 null，交给调用方按活跃时间兜底。
  static Future<String?> resolveRememberedAgentChannel({
    required LocalDatabaseService db,
    required String agentId,
    required String? remembered,
  }) async {
    if (remembered == null || remembered.isEmpty || agentId.isEmpty) return null;
    try {
      final channel = await db.getChannelById(remembered);
      if (channel == null ||
          channel.isGroup ||
          channel.isGroupBoundMemberSession ||
          channel.isSheBoundSession ||
          !channel.memberIds.contains(agentId)) {
        return null;
      }
      if (await db.countChannelMessages(remembered) > 0) return remembered;
      final drafts = getIt.isRegistered<ComposerDraftService>()
          ? getIt<ComposerDraftService>()
          : null;
      if (drafts != null &&
          drafts.getDraft(remembered).trimRight().isNotEmpty) {
        return remembered;
      }
    } catch (_) {
      // 会话被删掉 / 还没同步过来：保留活跃时间的兜底。
    }
    return null;
  }

  Future<ConversationSelection> _resolveSelection({
    required String channelId,
    String? messageId,
    String? agentId,
    String? agentName,
    String? agentAvatar,
  }) async {
    String? resolvedAgentId = agentId;
    String? resolvedAgentName = agentName;
    String? resolvedAvatar = agentAvatar;
    String? groupFamilyId;
    var resolvedChannelId = channelId;

    try {
      final db = getIt.isRegistered<LocalDatabaseService>()
          ? getIt<LocalDatabaseService>()
          : LocalDatabaseService();
      var channel = await db.getChannelById(channelId);
      if (channel == null) {
        // 提醒可能记的是主机会话 id（本地镜像叫 psess_<id>），也可能反过来。
        final synced = syncedPeerChannelId(channelId);
        channel = await db.getChannelById(synced);
        if (channel != null) resolvedChannelId = synced;
      }
      if (channel != null) {
        if (channel.isGroup) {
          groupFamilyId = channel.groupFamilyId;
        } else if (resolvedAgentId == null || resolvedAgentId.isEmpty) {
          final members = await db.getChannelMembers(resolvedChannelId);
          final agentMember = members.where((m) => m.isAgent).toList();
          if (agentMember.isNotEmpty) {
            resolvedAgentId = agentMember.first.id;
          }
        }
      }
      if (resolvedAgentId != null &&
          resolvedAgentId.isNotEmpty &&
          (resolvedAgentName == null || resolvedAgentName.isEmpty)) {
        final agent = await db.getRemoteAgentById(resolvedAgentId);
        if (agent != null) {
          resolvedAgentName = agent.name;
          resolvedAvatar ??= agent.avatar;
        }
      }
    } catch (e) {
      LoggerService().warning('Resolve channel failed: $e', tag: _tag);
    }

    return ConversationSelection(
      agentId: resolvedAgentId,
      agentName: resolvedAgentName,
      agentAvatar: resolvedAvatar,
      channelId: resolvedChannelId,
      groupFamilyId: groupFamilyId,
      highlightMessageId: messageId,
    );
  }
}
