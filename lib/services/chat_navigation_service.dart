import 'package:flutter/material.dart';

import '../models/conversation_selection.dart';
import '../screens/chat_screen.dart';
import '../service_locator.dart';
import 'local_database_service.dart';
import 'logger_service.dart';

/// Opens a chat session from notifications / global banner (mobile + desktop).
class ChatNavigationService {
  ChatNavigationService._();
  static final ChatNavigationService instance = ChatNavigationService._();

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
      LoggerService().warning('No navigator to open channel $channelId', tag: _tag);
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

    try {
      final db = getIt.isRegistered<LocalDatabaseService>()
          ? getIt<LocalDatabaseService>()
          : LocalDatabaseService();
      final channel = await db.getChannelById(channelId);
      if (channel != null) {
        if (channel.isGroup) {
          groupFamilyId = channel.groupFamilyId;
        } else if (resolvedAgentId == null || resolvedAgentId.isEmpty) {
          final members = await db.getChannelMembers(channelId);
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
      channelId: channelId,
      groupFamilyId: groupFamilyId,
      highlightMessageId: messageId,
    );
  }
}
