/// 主动消息通知界面
/// 展示 OpenClaw Agent 主动发起的聊天消息
library;

import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/acp_server_message.dart';
import '../services/acp_server_service.dart';
import '../widgets/common_widgets.dart';
import 'chat_screen.dart';

class IncomingMessageScreen extends StatefulWidget {
  final ACPServerService acpServerService;

  const IncomingMessageScreen({
    Key? key,
    required this.acpServerService,
  }) : super(key: key);

  @override
  State<IncomingMessageScreen> createState() => _IncomingMessageScreenState();
}

class _IncomingMessageScreenState extends State<IncomingMessageScreen> {
  final List<IncomingMessage> _messages = [];

  @override
  void initState() {
    super.initState();
    _listenToIncomingMessages();
  }

  void _listenToIncomingMessages() {
    widget.acpServerService.requestStream.listen((request) {
      if (request.requestType == ACPRequestType.initiateChat) {
        setState(() {
          _messages.insert(
            0,
            IncomingMessage(
              id: request.id,
              agentId: request.sourceAgentId ?? 'unknown',
              message: request.params?['message'] ?? '',
              timestamp: request.timestamp,
              isRead: false,
            ),
          );
        });

        // 显示通知
        _showNotification(request);
      }
    });
  }

  void _showNotification(ACPServerRequest request) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.message, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    request.sourceAgentId ?? 'Unknown Agent',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    request.params?['message'] ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: l10n.incoming_view,
          textColor: Colors.white,
          onPressed: () {
            // 跳转到消息详情
          },
        ),
        duration: const Duration(seconds: 5),
        backgroundColor: Colors.blue[700],
      ),
    );
  }

  void _markAsRead(IncomingMessage message) {
    setState(() {
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index != -1) {
        _messages[index] = message.copyWith(isRead: true);
      }
    });
  }

  void _deleteMessage(IncomingMessage message) {
    setState(() {
      _messages.removeWhere((m) => m.id == message.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final unreadCount = _messages.where((m) => !m.isRead).length;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.incoming_title),
            if (unreadCount > 0)
              Text(
                l10n.incoming_unreadCount(unreadCount),
                style: const TextStyle(fontSize: 12),
              ),
          ],
        ),
        actions: [
          if (_messages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: _showClearAllDialog,
              tooltip: l10n.incoming_clearAll,
            ),
        ],
      ),
      body: _messages.isEmpty
          ? EmptyState(
              title: l10n.incoming_noMessages,
              icon: Icons.inbox,
              message: l10n.incoming_noMessagesHint,
            )
          : ListView.separated(
              itemCount: _messages.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                return _buildMessageItem(_messages[index]);
              },
            ),
    );
  }

  Widget _buildMessageItem(IncomingMessage message) {
    final l10n = AppLocalizations.of(context);

    return Dismissible(
      key: Key(message.id),
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => _deleteMessage(message),
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: message.isRead ? null : Colors.blue[50],
        child: InkWell(
          onTap: () => _showMessageDetail(message),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(Icons.smart_toy, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            message.agentId,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            _formatTime(message.timestamp),
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!message.isRead)
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 12),

                // Message content
                Text(
                  message.message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),

                const SizedBox(height: 12),

                // Actions
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (!message.isRead)
                      TextButton.icon(
                        icon: const Icon(Icons.check, size: 16),
                        label: Text(l10n.incoming_markAsRead),
                        onPressed: () => _markAsRead(message),
                      ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.reply, size: 16),
                      label: Text(l10n.common_reply),
                      onPressed: () => _replyToMessage(message),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showMessageDetail(IncomingMessage message) {
    final l10n = AppLocalizations.of(context);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.message),
            const SizedBox(width: 8),
            Expanded(child: Text(message.agentId)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.incoming_time(_formatDateTime(message.timestamp)),
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              Text(message.message),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _markAsRead(message);
            },
            child: Text(l10n.incoming_markAsRead),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _replyToMessage(message);
            },
            child: Text(l10n.common_reply),
          ),
        ],
      ),
    );

    _markAsRead(message);
  }

  void _replyToMessage(IncomingMessage message) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          agentId: message.agentId,
          agentName: message.agentId,
        ),
      ),
    );
  }

  Future<void> _showClearAllDialog() async {
    final l10n = AppLocalizations.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.incoming_clearAllTitle),
        content: Text(l10n.incoming_clearAllContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.common_cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: Text(l10n.incoming_clearButton),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() {
        _messages.clear();
      });
    }
  }

  String _formatTime(DateTime dateTime) {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return l10n.incoming_justNow;
    } else if (difference.inHours < 1) {
      return l10n.incoming_minutesAgo(difference.inMinutes);
    } else if (difference.inDays < 1) {
      return l10n.incoming_hoursAgo(difference.inHours);
    } else if (difference.inDays < 7) {
      return l10n.incoming_daysAgo(difference.inDays);
    } else {
      return _formatDateTime(dateTime);
    }
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')} '
        '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }
}

/// 主动消息数据模型
class IncomingMessage {
  final String id;
  final String agentId;
  final String message;
  final DateTime timestamp;
  final bool isRead;

  IncomingMessage({
    required this.id,
    required this.agentId,
    required this.message,
    required this.timestamp,
    required this.isRead,
  });

  IncomingMessage copyWith({
    String? id,
    String? agentId,
    String? message,
    DateTime? timestamp,
    bool? isRead,
  }) {
    return IncomingMessage(
      id: id ?? this.id,
      agentId: agentId ?? this.agentId,
      message: message ?? this.message,
      timestamp: timestamp ?? this.timestamp,
      isRead: isRead ?? this.isRead,
    );
  }
}
