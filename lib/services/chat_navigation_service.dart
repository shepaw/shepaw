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
import 'local_database_service.dart';
import 'local_user_identity.dart';
import 'app_lifecycle_service.dart';
import 'logger_service.dart';
import 'route_gate.dart';

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
  Future<void> openChannel({
    required String channelId,
    String? messageId,
    String? agentId,
    String? agentName,
    String? agentAvatar,
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

    final desktop = _desktopHandler;
    if (desktop != null) {
      desktop(selection);
      return;
    }

    final nav = _navigatorKey?.currentState;
    if (nav == null) {
      LoggerService()
          .warning('No navigator to open channel $channelId', tag: _tag);
      return;
    }
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
    final channelId =
        await chatService.getLatestActiveChannelId(userId, agentId) ??
            chatService.generateChannelId(userId, agentId);
    await openChannel(
      channelId: channelId,
      agentId: agentId,
      agentName: agentName,
      agentAvatar: agentAvatar,
    );
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
