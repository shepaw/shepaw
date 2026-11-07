import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/closed_socket.dart';

void main() {
  test('recognises the dart:io closed-socket read error', () {
    expect(
      isReadingClosedSocket(
        const SocketException('Reading from a closed socket'),
      ),
      isTrue,
    );
    expect(
      isReadingClosedSocket(const SocketException('Connection refused')),
      isFalse,
    );
    expect(isReadingClosedSocket(StateError('WebSocket closed')), isFalse);
  });

  test('a closed socket or a dead session is a transport failure', () {
    expect(
      sendFailureIsDeadTransport(
        StateError('WebSocket closed'),
        socketClosed: false,
      ),
      isTrue,
    );
    expect(
      sendFailureIsDeadTransport(
        StateError('Noise session not ready'),
        socketClosed: false,
      ),
      isTrue,
    );
    expect(
      sendFailureIsDeadTransport(
        StateError('Connection closed'),
        socketClosed: false,
      ),
      isTrue,
    );
    expect(
      sendFailureIsDeadTransport(
        const SocketException('Reading from a closed socket'),
        socketClosed: false,
      ),
      isTrue,
    );
    expect(
      sendFailureIsDeadTransport(StateError('nope'), socketClosed: true),
      isTrue,
    );
    expect(
      sendFailureIsDeadTransport(
        StateError('encrypt failed'),
        socketClosed: false,
      ),
      isFalse,
    );
  });

  test('only inbound frames refresh the liveness clock', () {
    final connectedAt = DateTime.utc(2026, 11, 7, 14);
    final now = connectedAt.add(const Duration(seconds: 120));
    expect(
      peerInboundExpired(null, connectedAt, now, const Duration(seconds: 120)),
      isTrue,
    );
    expect(
      peerInboundExpired(
        now.subtract(const Duration(seconds: 30)),
        connectedAt,
        now,
        const Duration(seconds: 120),
      ),
      isFalse,
    );
    expect(
      peerInboundExpired(
        connectedAt,
        now,
        now,
        const Duration(seconds: 120),
      ),
      isTrue,
    );
  });
}
