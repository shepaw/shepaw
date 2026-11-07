import 'dart:io';

/// dart:io 在 TLS 读事件已经排进 Timer 之后才关掉 socket 时，会抛出这条
/// 异常，而且**不会**进到 `WebSocket.listen` 的 `onError` / `onDone`。
/// 调用方的连接状态会停在 `connected`，工作流页对着废连接一直转圈。
bool isReadingClosedSocket(Object error) {
  if (error is SocketException) {
    return error.message.contains('Reading from a closed socket');
  }
  return error.toString().contains('Reading from a closed socket');
}

/// 这次发送失败是不是传输层已经死了。
///
/// 死了就要丢掉连接并重连。留在 `connected` 上的话，工作流的
/// `flow_run_get` 会一直写进废 socket，刷新也没有用。
bool sendFailureIsDeadTransport(
  Object error, {
  required bool socketClosed,
}) {
  if (socketClosed || isReadingClosedSocket(error)) return true;
  if (error is StateError) {
    final message = error.message.toLowerCase();
    return message.contains('closed') ||
        message.contains('not ready') ||
        message.contains('no active transport');
  }
  return false;
}

/// 入站静默是否已经超过 [timeout]。
///
/// 只看对端帧。[lastReceivedAt] 为空表示连上之后还没收到任何帧，
/// 从 [connectedAt] 起算。本端自己的发送不能把这条计时拨回去。
bool peerInboundExpired(
  DateTime? lastReceivedAt,
  DateTime connectedAt,
  DateTime now,
  Duration timeout,
) =>
    now.difference(lastReceivedAt ?? connectedAt) >= timeout;
