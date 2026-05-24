import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/paired_peer.dart';
import '../models/peer_message.dart';
import '../services/peer_connection_manager.dart';
import '../services/peer_pairing_service.dart';
import '../services/peer_storage_service.dart';

/// P2P 聊天页面
class PeerChatScreen extends StatefulWidget {
  final PairedPeer peer;

  const PeerChatScreen({super.key, required this.peer});

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

    // 监听回执事件，实时更新消息投递状态
    _ackSub = PeerConnectionManager.instance.ackEvents.listen((ack) {
      if (mounted) {
        setState(() {
          for (var i = 0; i < _messages.length; i++) {
            if (_messages[i].id == ack.messageId) {
              final newDelivery = ack.status == 'read'
                  ? PeerMessageDelivery.read
                  : PeerMessageDelivery.delivered;
              _messages[i] = _messages[i].copyWith(delivery: newDelivery);
              break;
            }
          }
        });
      }
    });
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

  Future<void> _editDisplayName() async {
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController(text: _displayName);
        return AlertDialog(
          title: const Text('修改备注'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '输入备注名称',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (newName != null && newName.isNotEmpty && newName != _displayName) {
      await PeerStorageService().updateDeviceName(widget.peer.id, newName);
      if (mounted) {
        setState(() => _displayName = newName);
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
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _editDisplayName,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_displayName),
              Text(
                _connectionStateText(),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _connectionStateColor(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Icon(
              _connectionState == PeerConnectionState.connected
                  ? Icons.lock
                  : Icons.lock_open,
              size: 18,
              color: _connectionState == PeerConnectionState.connected
                  ? Colors.green
                  : Colors.grey,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 加密提示条
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
            color: Colors.green.withOpacity(0.08),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.enhanced_encryption, size: 14, color: Colors.green[700]),
                const SizedBox(width: 6),
                Text(
                  '消息已端到端加密',
                  style: TextStyle(fontSize: 12, color: Colors.green[700]),
                ),
              ],
            ),
          ),

          // 消息列表
          Expanded(
            child: Stack(
              children: [
                _messages.isEmpty
                    ? Center(
                        child: Text(
                          '暂无消息\n发送第一条消息开始对话',
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
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
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
                hintText: isConnected ? '输入消息...' : '设备未连接',
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
              enabled: isConnected,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: isConnected ? _sendMessage : null,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isConnected ? Theme.of(context).primaryColor : Colors.grey[300],
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.send,
                size: 18,
                color: isConnected ? Colors.white : Colors.grey[500],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _connectionStateText() {
    switch (_connectionState) {
      case PeerConnectionState.connected:
        return '在线 · 端到端加密';
      case PeerConnectionState.connecting:
        return '连接中...';
      case PeerConnectionState.disconnected:
        return '离线';
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

  const _PeerMessageBubble({
    required this.message,
    required this.isMyMessage,
    required this.peerName,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isMyMessage ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          // 对方头像（左侧）
          if (!isMyMessage) ...[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Colors.teal[100],
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.smartphone, size: 16, color: Colors.teal[700]),
            ),
            const SizedBox(width: 8),
          ],

          // 消息内容
          Flexible(
            child: Column(
              crossAxisAlignment: isMyMessage
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                // 对方名字
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

                // 气泡
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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

                // 时间 + 状态
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatTime(message.timestamp),
                        style: const TextStyle(fontSize: 10, color: Colors.grey),
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

          // 自己的消息右侧留白
          if (isMyMessage) const SizedBox(width: 40),
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
        return const Icon(Icons.done_all, size: 12, color: Colors.blue);
      case PeerMessageDelivery.failed:
        return const Icon(Icons.error_outline, size: 12, color: Colors.red);
    }
  }

  String _formatTime(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final timeStr = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return timeStr;
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (dt.year == yesterday.year && dt.month == yesterday.month && dt.day == yesterday.day) {
      return '昨天 $timeStr';
    }
    return '${dt.month}/${dt.day} $timeStr';
  }
}
