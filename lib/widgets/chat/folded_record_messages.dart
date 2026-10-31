import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/message.dart';
import '../../peer/models/folded_sessions.dart';
import '../../peer/services/peer_agent_client_service.dart';
import '../message_bubble.dart';

/// 折叠组里那份只读记录的一条消息。
///
/// 私聊的历史（[PeerHistoryMessage]）和群聊视角（[GroupViewMessage]）形状不同，
/// 这里折成同一个，好共用私聊那一套气泡渲染，而不是各画一份纯文本卡片。
class FoldedRecordMessage {
  const FoldedRecordMessage({
    required this.role,
    required this.content,
    this.id,
    this.createdAt,
  });

  /// `user` 或 `agent`。
  final String role;
  final String content;
  final String? id;
  final DateTime? createdAt;

  bool get isUser => role == 'user';

  static FoldedRecordMessage fromPeerHistory(PeerHistoryMessage message) =>
      FoldedRecordMessage(
        role: message.role,
        content: message.content,
        id: message.messageId,
        createdAt: message.createdAt,
      );

  static FoldedRecordMessage fromGroupView(GroupViewMessage message) =>
      FoldedRecordMessage(
        role: message.role == 'user' ? 'user' : 'agent',
        content: message.content,
        id: message.id,
        createdAt: DateTime.tryParse(message.createdAt),
      );

  /// 折成气泡要的 [Message]。主机没给时间时用 0：气泡自己不显示时间戳，
  /// 排序按主机返回的顺序。
  Message asMessage(String channelId, int index) => Message.simple(
        id: id ?? '$channelId#$index',
        channelId: channelId,
        senderId: isUser ? 'user' : 'agent',
        senderName: isUser ? 'user' : 'agent',
        senderType: isUser ? 'user' : 'agent',
        content: content,
        timestamp: createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
        type: MessageType.text,
      );
}

/// 只读记录的正文：直接用私聊的 [MessageBubble]，不再自己画彩色方块。
///
/// 只读，所以没有输入框、没有交互卡回调；正文可以长按选中复制（记录页不涉及
/// 抽屉手势，[MessageBubble.textSelectionEnabled] 常开）。
class FoldedRecordMessageList extends StatelessWidget {
  const FoldedRecordMessageList({
    super.key,
    required this.channelId,
    required this.messages,
    this.loading = false,
    this.hasMore = false,
    this.onLoadMore,
  });

  /// 只用来给 [Message] 凑 id，不参与渲染。
  final String channelId;
  final List<FoldedRecordMessage> messages;
  final bool loading;
  final bool hasMore;
  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final trailing = hasMore || loading;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      itemCount: messages.length + (trailing ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= messages.length) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: loading
                  ? const CircularProgressIndicator()
                  : TextButton(
                      onPressed: onLoadMore,
                      child: Text(l10n.folder_loadMore),
                    ),
            ),
          );
        }
        final record = messages[index];
        return MessageBubble(
          message: record.asMessage(channelId, index),
          isMyMessage: record.isUser,
          showAvatar: false,
          showSenderName: false,
          textSelectionEnabled: true,
        );
      },
    );
  }
}
