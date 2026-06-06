import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/paired_peer.dart';
import '../models/peer_message.dart';
import '../services/peer_connection_manager.dart';
import '../services/peer_pairing_service.dart';
import '../services/peer_storage_service.dart';
import '../../l10n/app_localizations.dart';
import '../../models/remote_agent.dart';
import '../../screens/chat_screen.dart';
import '../../theme/app_theme.dart';
import '../../utils/layout_utils.dart';
import 'peer_settings_screen.dart';
import '../widgets/peer_agent_list_panel.dart';
import '../widgets/peer_device_icon.dart';

/// P2P 聊天页面
class PeerChatScreen extends StatefulWidget {
  final PairedPeer peer;
  final bool embedded;
  final ValueChanged<RemoteAgent>? onAgentSelected;

  const PeerChatScreen({
    super.key,
    required this.peer,
    this.embedded = false,
    this.onAgentSelected,
  });

  @override
  State<PeerChatScreen> createState() => _PeerChatScreenState();
}

class _PeerChatScreenState extends State<PeerChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _uuid = const Uuid();

  late String _displayName;
  String? _myDeviceId;
  List<PeerMessage> _messages = [];
  StreamSubscription? _messageSub;
  StreamSubscription? _eventSub;
  StreamSubscription? _ackSub;
  PeerConnectionState _connectionState = PeerConnectionState.disconnected;
  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    _displayName = widget.peer.deviceName;
    _initDeviceId();
    _loadMessages();
    _subscribeToMessages();
    _connectionState = PeerConnectionManager.instance.getPeerState(widget.peer.id);
    _tryConnect();

    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _messageSub?.cancel();
    _eventSub?.cancel();
    _ackSub?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.offset;
    // 距离底部超过 200px 时显示按钮
    final shouldShow = (maxScroll - currentScroll) > 200;
    if (shouldShow != _showScrollToBottom) {
      setState(() => _showScrollToBottom = shouldShow);
    }
  }

  Future<void> _initDeviceId() async {
    _myDeviceId = await PeerPairingService.instance.getDeviceId();
  }

  Future<void> _loadMessages() async {
    final messages = await PeerStorageService().getMessages(widget.peer.id);
    if (mounted) {
      setState(() {
        _messages = messages.reversed.toList();
      });
      // 加载后滚到底部
      _scrollToBottom(animate: false);
      // 标记所有对方发来的未读消息为已读
      final unreadIds = _messages
          .where((m) => !_isMyMessage(m) && m.delivery != PeerMessageDelivery.read)
          .map((m) => m.id)
          .toList();
      if (unreadIds.isNotEmpty) {
        _sendReadReceipt(unreadIds);
      }
    }
  }

  /// 发送已读回执
  Future<void> _sendReadReceipt(List<String> messageIds) async {
    await PeerConnectionManager.instance.markMessagesAsRead(
      widget.peer.id,
      messageIds,
    );
  }

  void _subscribeToMessages() {
    _messageSub = PeerConnectionManager.instance.messages
        .where((msg) => msg.peerId == widget.peer.id)
        .listen((msg) {
      if (mounted) {
        setState(() => _messages.add(msg));
        _scrollToBottom();
        // 收到消息时立即标记已读
        _sendReadReceipt([msg.id]);
      }
    });

    _eventSub = PeerConnectionManager.instance.events
        .where((event) => event.peerId == widget.peer.id)
        .listen((event) {
      if (mounted) {
        setState(() {
          _connectionState = PeerConnectionManager.instance.getPeerState(widget.peer.id);
        });
      }
    });

    // 监听回执事件，实时更新消息投递状态。
    // 包括本地发送成功事件（'sent'）以及对端回执（'delivered' / 'read'）。
    _ackSub = PeerConnectionManager.instance.ackEvents.listen((ack) {
      if (!mounted) return;
      final newDelivery = _deliveryFromAckStatus(ack.status);
      if (newDelivery == null) return;
      setState(() {
        for (var i = 0; i < _messages.length; i++) {
          if (_messages[i].id == ack.messageId) {
            // 防止状态回退：仅允许向更「已送达」的方向推进。
            if (_deliveryRank(newDelivery) >
                _deliveryRank(_messages[i].delivery)) {
              _messages[i] = _messages[i].copyWith(delivery: newDelivery);
            }
            break;
          }
        }
      });
    });
  }

  PeerMessageDelivery? _deliveryFromAckStatus(String status) {
    switch (status) {
      case 'sent':
        return PeerMessageDelivery.sent;
      case 'delivered':
        return PeerMessageDelivery.delivered;
      case 'read':
        return PeerMessageDelivery.read;
      default:
        return null;
    }
  }

  /// 投递状态的推进等级，用于防止状态回退（数值越大表示越「已送达」）。
  int _deliveryRank(PeerMessageDelivery delivery) {
    switch (delivery) {
      case PeerMessageDelivery.failed:
        return -1;
      case PeerMessageDelivery.pending:
        return 0;
      case PeerMessageDelivery.sent:
        return 1;
      case PeerMessageDelivery.delivered:
        return 2;
      case PeerMessageDelivery.read:
        return 3;
    }
  }

  Future<void> _tryConnect() async {
    final currentState = PeerConnectionManager.instance.getPeerState(widget.peer.id);
    if (currentState == PeerConnectionState.connected) return;

    if (mounted) {
      setState(() => _connectionState = PeerConnectionState.connecting);
    }

    try {
      await PeerConnectionManager.instance.connectToPeer(widget.peer);
    } catch (_) {}
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final message = PeerMessage(
      id: _uuid.v4(),
      peerId: widget.peer.id,
      senderId: _myDeviceId ?? 'self',
      type: PeerMessageType.text,
      content: text,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      delivery: PeerMessageDelivery.pending,
    );

    _textController.clear();
    setState(() => _messages.add(message));
    _scrollToBottom();

    await PeerStorageService().saveMessage(message);
    await PeerConnectionManager.instance.sendMessage(widget.peer.id, message);
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (animate) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  Future<void> _showAgentList() async {
    final l10n = AppLocalizations.of(context);
    final isConnected =
        _connectionState == PeerConnectionState.connected;

    final content = PeerAgentListPanel(
      peerId: widget.peer.id,
      isPeerConnected: isConnected,
      onPeerAgentTap: _openAgentChat,
    );

    if (LayoutUtils.isDesktopLayout(context)) {
      await LayoutUtils.showRightDrawer(context: context, builder: (_) => content);
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => Scaffold(
            appBar: AppBar(
              title: Text(l10n.peerChat_agentList),
              elevation: 1,
            ),
            body: content,
          ),
        ),
      );
    }
  }

  void _openAgentChat(RemoteAgent agent) {
    Navigator.of(context).pop();

    if (widget.embedded && widget.onAgentSelected != null) {
      widget.onAgentSelected!(agent);
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          agentId: agent.id,
          agentName: agent.name,
          agentAvatar: agent.avatar,
        ),
      ),
    );
  }

  Future<void> _openSettings() async {
    final deleted = await PeerSettingsScreen.show(context, widget.peer);
    if (deleted == true && mounted) {
      // peer 被删除了，尝试退出聊天页
      // 在嵌入模式下 pop 可能无效（由父组件通过事件监听处理）
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } else {
      // 可能改了名称，重新加载
      final updatedPeer = await PeerStorageService().getPeerById(widget.peer.id);
      if (updatedPeer != null && mounted) {
        setState(() => _displayName = updatedPeer.deviceName);
      }
    }
  }

  bool _isMyMessage(PeerMessage msg) {
    if (_myDeviceId != null) {
      return msg.senderId == _myDeviceId;
    }
    return msg.senderId != widget.peer.deviceId;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // 嵌入桌面右面板时没有返回按钮（leading），title 会贴左边界；
    // 此时给一点左间距，移动端有返回箭头则保持紧凑。
    final hasLeading = Navigator.of(context).canPop();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: hasLeading ? 0 : 16,
        title: GestureDetector(
          onTap: _openSettings,
          child: Row(
            children: [
              PeerDeviceIcon(peer: widget.peer, size: 36, borderRadius: 10),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _displayName,
                            style: const TextStyle(fontSize: 16),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.peer.pairingRole != null) ...[
                          const SizedBox(width: 6),
                          _buildRoleBadge(l10n),
                        ],
                      ],
                    ),
                    _buildConnectionStatus(l10n),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.smart_toy_outlined, size: 20),
            tooltip: l10n.peerChat_agentList,
            onPressed: _showAgentList,
          ),
        ],
      ),
      body: Column(
        children: [
          // 消息列表
          Expanded(
            child: Stack(
              children: [
                _messages.isEmpty
                    ? Center(
                        child: Text(
                          l10n.peerChat_emptyMessages,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey[400], height: 1.5),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          return _PeerMessageBubble(
                            message: _messages[index],
                            isMyMessage: _isMyMessage(_messages[index]),
                            peerName: _displayName,
                            deviceStyle: PeerDeviceStyle.forPeer(widget.peer),
                          );
                        },
                      ),

                // 跳到底部按钮
                if (_showScrollToBottom)
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: FloatingActionButton.small(
                      onPressed: () => _scrollToBottom(),
                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.keyboard_arrow_down,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // 输入区域
          _buildInputArea(l10n),
        ],
      ),
    );
  }

  Widget _buildInputArea(AppLocalizations l10n) {
    final isConnected = _connectionState == PeerConnectionState.connected;

    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: Colors.grey[300]!, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              decoration: InputDecoration(
                // 离线时仍可输入：消息会进入待发队列，连接恢复后自动补发
                hintText: isConnected ? l10n.peerChat_hintOnline : l10n.peerChat_hintOffline,
                hintStyle: TextStyle(color: Colors.grey[400]),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Colors.grey[100],
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sendMessage,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.send,
                size: 18,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoleBadge(AppLocalizations l10n) {
    final isInitiator = widget.peer.pairingRole == PeerPairingRole.initiator;
    final color = PeerDeviceStyle.forPeer(widget.peer).labelColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isInitiator ? Icons.call_made : Icons.call_received,
            size: 11,
            color: color,
          ),
          const SizedBox(width: 3),
          Text(
            widget.peer.pairingRoleShortLabel(l10n) ?? '',
            style: TextStyle(fontSize: 11, color: color),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionStatus(AppLocalizations l10n) {
    final textStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: _connectionStateColor(),
    );

    // 已连接时，把端到端加密锁内联展示在“在线”与“端到端加密”之间
    if (_connectionState == PeerConnectionState.connected) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.peerChat_statusOnlinePrefix, style: textStyle),
          Icon(Icons.lock, size: 12, color: _connectionStateColor()),
          const SizedBox(width: 3),
          Text(l10n.peerChat_e2eEncryption, style: textStyle),
        ],
      );
    }

    return Text(_connectionStateText(l10n), style: textStyle);
  }

  String _connectionStateText(AppLocalizations l10n) {
    switch (_connectionState) {
      case PeerConnectionState.connected:
        return l10n.peerChat_statusOnline;
      case PeerConnectionState.connecting:
        return l10n.peerChat_statusConnecting;
      case PeerConnectionState.disconnected:
        return l10n.peerChat_statusOffline;
    }
  }

  Color _connectionStateColor() {
    switch (_connectionState) {
      case PeerConnectionState.connected:
        return Colors.green;
      case PeerConnectionState.connecting:
        return Colors.orange;
      case PeerConnectionState.disconnected:
        return Colors.grey;
    }
  }
}

/// 消息气泡
class _PeerMessageBubble extends StatelessWidget {
  final PeerMessage message;
  final bool isMyMessage;
  final String peerName;
  final PeerDeviceStyle deviceStyle;

  const _PeerMessageBubble({
    required this.message,
    required this.isMyMessage,
    required this.peerName,
    required this.deviceStyle,
  });

  static const _avatarSize = 32.0;
  static const _avatarGap = 8.0;

  @override
  Widget build(BuildContext context) {
    final maxBubbleWidth = MediaQuery.sizeOf(context).width * 0.72;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 对方头像（左侧）
          if (!isMyMessage) ...[
            Container(
              width: _avatarSize,
              height: _avatarSize,
              decoration: BoxDecoration(
                color: deviceStyle.backgroundColor,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.smartphone, size: 16, color: deviceStyle.iconColor),
            ),
            const SizedBox(width: _avatarGap),
          ],

          // 消息内容：己方靠右贴齐列表边距（12px），对方保留左侧头像区
          Expanded(
            child: Align(
              alignment:
                  isMyMessage ? Alignment.centerRight : Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxBubbleWidth),
                child: Column(
                  crossAxisAlignment: isMyMessage
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    if (!isMyMessage)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          peerName,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: isMyMessage
                            ? Theme.of(context).primaryColor
                            : Colors.grey[200],
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        message.content,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.4,
                          color: isMyMessage ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _formatTime(context, message.timestamp),
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                            ),
                          ),
                          if (isMyMessage) ...[
                            const SizedBox(width: 4),
                            _buildDeliveryIcon(message.delivery),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeliveryIcon(PeerMessageDelivery delivery) {
    switch (delivery) {
      case PeerMessageDelivery.pending:
        return const Icon(Icons.access_time, size: 12, color: Colors.grey);
      case PeerMessageDelivery.sent:
        return const Icon(Icons.check, size: 12, color: Colors.grey);
      case PeerMessageDelivery.delivered:
        return const Icon(Icons.done_all, size: 12, color: Colors.grey);
      case PeerMessageDelivery.read:
        return const Icon(Icons.done_all, size: 12, color: AppColors.primary);
      case PeerMessageDelivery.failed:
        return const Icon(Icons.error_outline, size: 12, color: Colors.red);
    }
  }

  String _formatTime(BuildContext context, int timestamp) {
    final l10n = AppLocalizations.of(context);
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final timeStr = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return timeStr;
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (dt.year == yesterday.year && dt.month == yesterday.month && dt.day == yesterday.day) {
      return l10n.peerChat_yesterday(timeStr);
    }
    return '${dt.month}/${dt.day} $timeStr';
  }
}
