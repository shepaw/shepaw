/// High-level Noise session API used by `ACPAgentConnection`.
///
/// Wraps [HandshakeState] and the two post-split transport keys. Exposes:
///
///   - `NoiseSession.initiator(...)` — construct from identity + pinned peer static
///   - `NoiseSession.responder(...)` — construct from identity (learns peer from msg 1)
///   - `writeHandshake1` / `readHandshake2` — initiator flow
///   - `readHandshake1` / `writeHandshake2` — responder flow (unused in the app, tested here for symmetry)
///   - `encrypt(plaintext)` / `decrypt(ciphertext)` — transport
///   - `close()` — zero keys, release state
///
/// Symmetric with the TS SDK's `NoiseSession` class; method names line up to
/// make the two halves of the v2 protocol easy to cross-read.
library;

import 'dart:typed_data';

import 'noise_handshake_state.dart';
import 'noise_primitives.dart';

/// Thrown when a transport AEAD operation fails (tag mismatch, nonce overflow,
/// wrong-phase call, etc). Fatal for the session — callers should close the WS.
class NoiseTransportError implements Exception {
  final String message;
  NoiseTransportError(this.message);
  @override
  String toString() => 'NoiseTransportError: $message';
}

/// Information returned to the responder after consuming handshake message 1.
/// Used to verify `agentId` inside the payload and to remember the peer's
/// static key for future per-device authorization.
class ResponderHandshake1Result {
  final Uint8List msg1Payload;
  final Uint8List peerStaticPublicKey;
  ResponderHandshake1Result({
    required this.msg1Payload,
    required this.peerStaticPublicKey,
  });
}

/// Information returned to the initiator after consuming handshake message 2.
/// The peer static pubkey is the same one you pinned; exposing it here is a
/// convenience for fingerprint re-verification in [NoiseSession.verifyPeer].
class InitiatorHandshake2Result {
  final Uint8List msg2Payload;
  final Uint8List peerStaticPublicKey;
  InitiatorHandshake2Result({
    required this.msg2Payload,
    required this.peerStaticPublicKey,
  });
}

enum _Phase {
  // Initiator: write msg 1, then read msg 2.
  initiatorAwaitWrite1,
  initiatorAwaitRead2,
  // Responder: read msg 1, then write msg 2.
  responderAwaitRead1,
  responderAwaitWrite2,
  ready,
  closed,
}

class NoiseSession {
  final bool isInitiator;
  HandshakeState? _hs;

  /// Pinned peer static pub — for the initiator, set at construct time and
  /// verified during handshake; for the responder, learned from msg 1.
  Uint8List? _peerStaticPublicKey;

  /// Transport CipherState keys (32 bytes each), set after handshake.
  Uint8List? _sendKey;
  Uint8List? _recvKey;

  /// Nonces for `_sendKey` and `_recvKey`. Incremented on each encrypt/decrypt.
  int _sendNonce = 0;
  int _recvNonce = 0;

  _Phase _phase;

  NoiseSession._(
    this.isInitiator,
    this._hs,
    this._peerStaticPublicKey,
    this._phase,
  );

  // ── Factories ───────────────────────────────────────────────────────────

  /// Initiator side — typical for the Shepaw app.
  ///
  /// `pinnedPeerStaticPublicKey` is the responder's 32-byte static public key
  /// (the same key whose SHA-256 first 8 bytes appear in the URL `#fp=`). The
  /// handshake will fail if the real responder's key doesn't match.
  ///
  /// `ephemeralForTesting` lets interop tests inject a known ephemeral
  /// keypair so the wire output is byte-reproducible. Production code MUST
  /// NOT pass this.
  static Future<NoiseSession> initiator({
    required Uint8List staticPublicKey,
    required Uint8List staticPrivateKey,
    required Uint8List pinnedPeerStaticPublicKey,
    List<int>? prologue,
    ({Uint8List privateKey, Uint8List publicKey})? ephemeralForTesting,
  }) async {
    final hs = await HandshakeState.initialize(
      initiator: true,
      staticPublicKey: staticPublicKey,
      staticPrivateKey: staticPrivateKey,
      remoteStaticPublicKey: pinnedPeerStaticPublicKey,
      prologue: prologue,
      ephemeralForTesting: ephemeralForTesting,
    );
    return NoiseSession._(
      true,
      hs,
      Uint8List.fromList(pinnedPeerStaticPublicKey),
      _Phase.initiatorAwaitWrite1,
    );
  }

  /// Responder side — included for test coverage and potential future use
  /// (e.g., running another Dart process as the agent for debugging).
  static Future<NoiseSession> responder({
    required Uint8List staticPublicKey,
    required Uint8List staticPrivateKey,
    List<int>? prologue,
    ({Uint8List privateKey, Uint8List publicKey})? ephemeralForTesting,
  }) async {
    final hs = await HandshakeState.initialize(
      initiator: false,
      staticPublicKey: staticPublicKey,
      staticPrivateKey: staticPrivateKey,
      prologue: prologue,
      ephemeralForTesting: ephemeralForTesting,
    );
    return NoiseSession._(
      false,
      hs,
      null,
      _Phase.responderAwaitRead1,
    );
  }

  // ── Getters ─────────────────────────────────────────────────────────────

  bool get ready => _phase == _Phase.ready;

  /// Peer's 32-byte static public key. For the initiator this is set at
  /// construct time; for the responder it's set after `readHandshake1`.
  Uint8List get peerStaticPublicKey {
    final p = _peerStaticPublicKey;
    if (p == null) {
      throw NoiseTransportError('peer static public key not yet known');
    }
    return p;
  }

  // ── Initiator flow ──────────────────────────────────────────────────────

  /// Build the initiator's first handshake message.
  Future<Uint8List> writeHandshake1(List<int> payload) async {
    _requirePhase(_Phase.initiatorAwaitWrite1, 'writeHandshake1');
    final w = await _hs!.writeMessage(payload);
    _phase = _Phase.initiatorAwaitRead2;
    return w.message;
  }

  /// Consume the responder's handshake message 2 and complete the handshake.
  Future<InitiatorHandshake2Result> readHandshake2(List<int> message) async {
    _requirePhase(_Phase.initiatorAwaitRead2, 'readHandshake2');
    final r = await _hs!.readMessage(message);
    if (r.split == null) {
      _phase = _Phase.closed;
      throw NoiseTransportError('IK readMessage completed without a split');
    }
    _installTransportKeysInitiator(r.split!);
    return InitiatorHandshake2Result(
      msg2Payload: r.payload,
      peerStaticPublicKey: peerStaticPublicKey,
    );
  }

  // ── Responder flow ──────────────────────────────────────────────────────

  Future<ResponderHandshake1Result> readHandshake1(List<int> message) async {
    _requirePhase(_Phase.responderAwaitRead1, 'readHandshake1');
    final r = await _hs!.readMessage(message);
    // After reading IK msg 1, the remote static is known.
    final learnedPeer = _hs!.remoteStaticPublicKey;
    if (learnedPeer == null) {
      _phase = _Phase.closed;
      throw NoiseTransportError('responder did not learn peer static after msg 1');
    }
    _peerStaticPublicKey = Uint8List.fromList(learnedPeer);
    _phase = _Phase.responderAwaitWrite2;
    return ResponderHandshake1Result(
      msg1Payload: r.payload,
      peerStaticPublicKey: _peerStaticPublicKey!,
    );
  }

  Future<Uint8List> writeHandshake2(List<int> payload) async {
    _requirePhase(_Phase.responderAwaitWrite2, 'writeHandshake2');
    final w = await _hs!.writeMessage(payload);
    if (w.split == null) {
      _phase = _Phase.closed;
      throw NoiseTransportError('IK writeMessage completed without a split');
    }
    _installTransportKeysResponder(w.split!);
    return w.message;
  }

  // ── Transport ───────────────────────────────────────────────────────────

  /// AEAD-encrypt `plaintext` for the peer. Nonce auto-increments.
  /// Empty AD. `ciphertext = aead(plaintext) || 16-byte tag`.
  Future<Uint8List> encrypt(List<int> plaintext) async {
    if (_phase != _Phase.ready || _sendKey == null) {
      throw NoiseTransportError('session not ready for encryption');
    }
    if (_sendNonce >= _nonceHardLimit) {
      _phase = _Phase.closed;
      throw NoiseTransportError('send nonce exhausted');
    }
    try {
      final ct = await noiseAeadEncrypt(
        key: _sendKey!,
        counter: _sendNonce,
        ad: const <int>[],
        plaintext: plaintext,
      );
      _sendNonce += 1;
      return ct;
    } catch (e) {
      _phase = _Phase.closed;
      rethrow;
    }
  }

  /// AEAD-decrypt a transport frame. Nonce auto-increments. Throws
  /// `NoiseTransportError` on tag failure — do NOT echo the reason to peer.
  Future<Uint8List> decrypt(List<int> ciphertext) async {
    if (_phase != _Phase.ready || _recvKey == null) {
      throw NoiseTransportError('session not ready for decryption');
    }
    if (_recvNonce >= _nonceHardLimit) {
      _phase = _Phase.closed;
      throw NoiseTransportError('recv nonce exhausted');
    }
    try {
      final pt = await noiseAeadDecrypt(
        key: _recvKey!,
        counter: _recvNonce,
        ad: const <int>[],
        ciphertextWithTag: ciphertext,
      );
      _recvNonce += 1;
      return pt;
    } catch (e) {
      // Close on any decrypt failure. Callers should propagate a generic
      // "session corrupted" error without including the underlying message.
      _phase = _Phase.closed;
      throw NoiseTransportError('decrypt failed');
    }
  }

  void close() {
    _sendKey?.fillRange(0, _sendKey!.length, 0);
    _recvKey?.fillRange(0, _recvKey!.length, 0);
    _sendKey = null;
    _recvKey = null;
    _hs = null;
    _phase = _Phase.closed;
  }

  // ── Internals ───────────────────────────────────────────────────────────

  /// Soft limit well below 2^64 — we refuse to send or receive beyond this.
  /// At 2^63 the library's underlying counter is still safe; capping here
  /// mostly protects against pathological bugs or DoS amplification.
  static const int _nonceHardLimit = 1 << 62;

  void _requirePhase(_Phase expected, String op) {
    if (_phase != expected) {
      throw NoiseTransportError('$op called in phase ${_phase.name} (expected ${expected.name})');
    }
  }

  void _installTransportKeysInitiator(NoiseSplit split) {
    // Initiator: send = c2, recv = c1.
    //
    // This matches the TS `noise-protocol` library: after `readMessage`
    // completes (which is what the initiator does for msg2), the library
    // assigns `rx=c1, tx=c2` (handshake-state.js: `split(ss, rx, tx, ...)`).
    // The Shepaw TS SDK then sets `sendState=tx, recvState=rx`, so on the
    // wire the initiator encrypts with c2 and decrypts with c1.
    //
    // Earlier code had this reversed (send=c1, recv=c2). That was
    // self-consistent with the matching reversal in the responder half
    // below (so Dart↔Dart handshake + transport tests passed), but
    // incompatible with the TS agent: the first post-handshake ping would
    // close with WS 4409 ("decrypt failed") on the server and the reply
    // timeout on the client.
    _sendKey = split.c2Key;
    _recvKey = split.c1Key;
    _sendNonce = 0;
    _recvNonce = 0;
    _hs = null;
    _phase = _Phase.ready;
  }

  void _installTransportKeysResponder(NoiseSplit split) {
    // Responder: send = c1, recv = c2.
    // See _installTransportKeysInitiator for rationale. The TS library's
    // `writeMessage`-path split is `split(ss, tx, rx, ...)` → tx=c1, rx=c2,
    // so the responder encrypts with c1 and decrypts with c2.
    _sendKey = split.c1Key;
    _recvKey = split.c2Key;
    _sendNonce = 0;
    _recvNonce = 0;
    _hs = null;
    _phase = _Phase.ready;
  }
}
