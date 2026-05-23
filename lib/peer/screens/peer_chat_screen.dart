import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/paired_peer.dart';
import '../models/peer_message.dart';
import '../services/peer_connection_manager.dart';
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
  List<PeerMessage> _messages = [];
  StreamSubscription? _messageSub;
  StreamSubscription? _eventSub;
  PeerConnectionState _connectionState = PeerConnectionState.disconnected;

  @override
  void initState() {
    super.initState();
    _displayName = widget.peer.deviceName;
    _loadMessages();
    _subscribeToMessages();
    _connectionState = PeerConnectionManager.instance.getPeerState(widget.peer.id);
    // 进入聊天页时自动尝试连接
    _tryConnect();
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _messageSub?.cancel();
    _eventSub?.cancel();
    super.dispose();
  }

  /// 异步检测并建立连接
  Future<void> _tryConnect() async {
    final currentState = PeerConnectionManager.instance.getPeerState(widget.peer.id);
    if (currentState == PeerConnectionState.connected) return;

    if (mounted) {
      setState(() => _connectionState = PeerConnectionState.connecting);
    }

    try {
      await PeerConnectionManager.instance.connectToPeer(widget.peer);
    } catch (_) {
      // 连接失败，状态会通过 events stream 更新
    }
  }

  Future<void> _loadMessages() async {
    final messages = await PeerStorageService().getMessages(widget.peer.id);
    if (mounted) {
      setState(() {
        _messages = messages.reversed.toList(); // 按时间正序
      });
    }
  }

  void _subscribeToMessages() {
    // 监听新消息
    _messageSub = PeerConnectionManager.instance.messages
        .where((msg) => msg.peerId == widget.peer.id)
        .listen((msg) {
      if (mounted) {
        setState(() => _messages.add(msg));
        _scrollToBottom();
      }
    });

    // 监听连接状态
    _eventSub = PeerConnectionManager.instance.events
        .where((event) => event.peerId == widget.peer.id)
        .listen((event) {
      if (mounted) {
        setState(() {
          _connectionState = PeerConnectionManager.instance.getPeerState(widget.peer.id);
        });
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final message = PeerMessage(
      id: _uuid.v4(),
      peerId: widget.peer.id,
      senderId: 'self', // TODO: 使用实际 deviceId
      type: PeerMessageType.text,
      content: text,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      delivery: PeerMessageDelivery.pending,
    );

    _textController.clear();
    setState(() => _messages.add(message));
    _scrollToBottom();

    // 保存并发送
    await PeerStorageService().saveMessage(message);
    await PeerConnectionManager.instance.sendMessage(widget.peer.id, message);
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

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
                  color: _connectionStateColor(colorScheme),
                ),
              ),
            ],
          ),
        ),
        actions: [
          // 连接状态图标
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Icon(
              _connectionState == PeerConnectionState.connected
                  ? Icons.lock
                  : Icons.lock_open,
              size: 18,
              color: _connectionState == PeerConnectionState.connected
                  ? Colors.green
                  : colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 加密提示
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
            color: colorScheme.primaryContainer.withOpacity(0.3),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.enhanced_encryption, size: 14, color: colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  '端到端加密',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),

          // 消息列表
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text(
                      '暂无消息',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      return _MessageBubble(message: _messages[index]);
                    },
                  ),
          ),

          // 输入区域
          _buildInputArea(colorScheme),
        ],
      ),
    );
  }

  Widget _buildInputArea(ColorScheme colorScheme) {
    final isConnected = _connectionState == PeerConnectionState.connected;

    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              decoration: InputDecoration(
                hintText: isConnected ? '输入消息...' : '设备未连接',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest,
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
          IconButton.filled(
            onPressed: isConnected ? _sendMessage : null,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }

  String _connectionStateText() {
    switch (_connectionState) {
      case PeerConnectionState.connected:
        return '已连接 (加密)';
      case PeerConnectionState.connecting:
        return '连接中...';
      case PeerConnectionState.disconnected:
        return '未连接';
    }
  }

  Color _connectionStateColor(ColorScheme colorScheme) {
    switch (_connectionState) {
      case PeerConnectionState.connected:
        return Colors.green;
      case PeerConnectionState.connecting:
        return Colors.orange;
      case PeerConnectionState.disconnected:
        return colorScheme.onSurfaceVariant;
    }
  }
}

/// 消息气泡
class _MessageBubble extends StatelessWidget {
  final PeerMessage message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isSelf = message.senderId == 'self'; // TODO: 使用实际 deviceId
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: isSelf ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (isSelf) const Spacer(flex: 2),
          Flexible(
            flex: 5,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isSelf
                    ? colorScheme.primaryContainer
                    : colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: isSelf ? const Radius.circular(16) : const Radius.circular(4),
                  bottomRight: isSelf ? const Radius.circular(4) : const Radius.circular(16),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    message.content,
                    style: TextStyle(
                      color: isSelf
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatTime(message.timestamp),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: isSelf
                              ? colorScheme.onPrimaryContainer.withOpacity(0.6)
                              : colorScheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                      if (isSelf) ...[
                        const SizedBox(width: 4),
                        _deliveryIcon(message.delivery, colorScheme),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (!isSelf) const Spacer(flex: 2),
        ],
      ),
    );
  }

  Widget _deliveryIcon(PeerMessageDelivery delivery, ColorScheme colorScheme) {
    switch (delivery) {
      case PeerMessageDelivery.pending:
        return Icon(Icons.access_time, size: 12, color: colorScheme.onPrimaryContainer.withOpacity(0.5));
      case PeerMessageDelivery.sent:
        return Icon(Icons.check, size: 12, color: colorScheme.onPrimaryContainer.withOpacity(0.7));
      case PeerMessageDelivery.delivered:
        return Icon(Icons.done_all, size: 12, color: colorScheme.onPrimaryContainer.withOpacity(0.7));
      case PeerMessageDelivery.read:
        return Icon(Icons.done_all, size: 12, color: colorScheme.primary);
      case PeerMessageDelivery.failed:
        return Icon(Icons.error_outline, size: 12, color: colorScheme.error);
    }
  }

  String _formatTime(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
