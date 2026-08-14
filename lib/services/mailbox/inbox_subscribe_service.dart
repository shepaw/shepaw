/// App-level inbox push subscription (caller ↔ channel WebSocket).
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../logger_service.dart';

/// Server push when a sealed inbox reply is deposited.
class InboxMailReplyEvent {
  InboxMailReplyEvent({
    required this.replyId,
    required this.targetId,
    this.requestId,
    this.replyTo,
    this.messageId,
    this.kind,
  });

  final String replyId;
  final String targetId;
  final String? requestId;
  final String? replyTo;
  final String? messageId;
  final String? kind;

  factory InboxMailReplyEvent.fromJson(Map<String, dynamic> j) {
    return InboxMailReplyEvent(
      replyId: j['reply_id'] as String? ?? '',
      targetId: j['target_id'] as String? ?? '',
      requestId: j['request_id'] as String?,
      replyTo: j['reply_to'] as String?,
      messageId: j['message_id'] as String?,
      kind: j['kind'] as String?,
    );
  }
}

/// Singleton WebSocket to `/api/v1/inbox/subscribe` for [mail_reply] push.
class InboxSubscribeService {
  InboxSubscribeService._();

  static final InboxSubscribeService instance = InboxSubscribeService._();

  final _replyController = StreamController<InboxMailReplyEvent>.broadcast();
  final _targetRefCounts = <String, int>{};

  WebSocketChannel? _channel;
  StreamSubscription? _listenSub;
  String? _channelBase;
  String? _callerFp;
  bool _connecting = false;

  Stream<InboxMailReplyEvent> get onMailReply => _replyController.stream;

  static String wsUrlFromChannelBase(String channelBase, String callerFp) {
    final wsBase = channelBase
        .replaceFirst(RegExp(r'^https://'), 'wss://')
        .replaceFirst(RegExp(r'^http://'), 'ws://')
        .replaceAll(RegExp(r'/+$'), '');
    return '$wsBase/api/v1/inbox/subscribe'
        '?caller_fp=${Uri.encodeComponent(callerFp)}';
  }

  Future<void> ensureConnected({
    required String channelBase,
    required String callerFp,
  }) async {
    if (_channel != null &&
        _channelBase == channelBase &&
        _callerFp == callerFp) {
      return;
    }
    await _closeSocket();
    _channelBase = channelBase;
    _callerFp = callerFp;
    await _connect();
  }

  void subscribe(String targetId) {
    if (targetId.isEmpty) return;
    final prev = _targetRefCounts[targetId] ?? 0;
    _targetRefCounts[targetId] = prev + 1;
    if (prev == 0) {
      _send({'type': 'subscribe', 'targets': [targetId]});
    }
  }

  void unsubscribe(String targetId) {
    if (targetId.isEmpty) return;
    final prev = _targetRefCounts[targetId] ?? 0;
    if (prev <= 1) {
      _targetRefCounts.remove(targetId);
      _send({'type': 'unsubscribe', 'targets': [targetId]});
    } else {
      _targetRefCounts[targetId] = prev - 1;
    }
  }

  Future<void> disconnect() async {
    _targetRefCounts.clear();
    await _closeSocket();
  }

  Future<void> _closeSocket() async {
    await _listenSub?.cancel();
    _listenSub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  Future<void> _connect() async {
    if (_connecting) return;
    final base = _channelBase;
    final fp = _callerFp;
    if (base == null || fp == null) return;

    _connecting = true;
    try {
      final uri = Uri.parse(wsUrlFromChannelBase(base, fp));
      _channel = IOWebSocketChannel.connect(uri);
      _listenSub = _channel!.stream.listen(
        _onFrame,
        onError: (Object e) {
          LoggerService().debug('InboxSubscribe WS error: $e', tag: 'InboxWS');
          _scheduleReconnect();
        },
        onDone: _scheduleReconnect,
      );
      if (_targetRefCounts.isNotEmpty) {
        _send({
          'type': 'subscribe',
          'targets': _targetRefCounts.keys.toList(),
        });
      }
    } catch (e) {
      LoggerService().warning('InboxSubscribe connect failed: $e', tag: 'InboxWS');
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _scheduleReconnect() {
    if (_channelBase == null || _callerFp == null) return;
    _channel = null;
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (_channelBase != null && _callerFp != null && _channel == null) {
        unawaited(_connect());
      }
    });
  }

  void _onFrame(dynamic frame) {
    try {
      final j = jsonDecode(frame as String) as Map<String, dynamic>;
      final type = j['type']?.toString() ?? '';
      if (type == 'mail_reply') {
        final event = InboxMailReplyEvent.fromJson(j);
        if (event.replyId.isNotEmpty) {
          _replyController.add(event);
        }
        return;
      }
      if (type == 'ping') {
        _send({'type': 'pong'});
      }
    } catch (e) {
      LoggerService().debug('InboxSubscribe frame parse: $e', tag: 'InboxWS');
    }
  }

  void _send(Map<String, dynamic> body) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode(body));
    } catch (e) {
      LoggerService().debug('InboxSubscribe send failed: $e', tag: 'InboxWS');
    }
  }
}
