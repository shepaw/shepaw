/// Noise `HandshakeState` (spec §5.3) driving the `IK` message pattern.
///
/// IK:
///   <- s                  (responder static pre-shared with initiator)
///   ...
///   -> e, es, s, ss       (message 1)
///   <- e, ee, se          (message 2)
///
/// Only IK is implemented — we're not shipping XX/KK/etc. Adding another
/// pattern would mean generalizing `writeMessage`/`readMessage` to consume a
/// token list, which is straightforward but not needed for v2.
///
/// Concurrency: one handshake state per connection; no internal locking. All
/// `write*` and `read*` methods must be called in sequence.
library;

import 'dart:typed_data';

import 'noise_primitives.dart';
import 'noise_symmetric_state.dart';

// ── Constants ─────────────────────────────────────────────────────────────

/// Exact protocol-name string used by Noise spec §8 for initializing
/// `SymmetricState.h`. Changing this string breaks interop.
const String noiseProtocolName = 'Noise_IK_25519_ChaChaPoly_BLAKE2b';

/// Prologue bound into the handshake hash. Matches the TS SDK's
/// `NOISE_PROLOGUE` byte-for-byte — any deviation here fails handshakes.
/// Bumped to `shepaw-acp/2.1` in v2.1 (authorized-peer allowlist replaces
/// token); v2 agents will fail the handshake against v2.1 apps and vice versa.
final Uint8List noisePrologueDefault = Uint8List.fromList('shepaw-acp/2.1'.codeUnits);

// ── Types ─────────────────────────────────────────────────────────────────

class NoiseHandshakeError implements Exception {
  final String message;
  NoiseHandshakeError(this.message);
  @override
  String toString() => 'NoiseHandshakeError: $message';
}

/// Result of a completed handshake — the two 32-byte transport keys.
class NoiseSplit {
  final Uint8List c1Key;
  final Uint8List c2Key;
  const NoiseSplit({required this.c1Key, required this.c2Key});
}

/// Generic handshake state driving IK. Opaque to callers.
class HandshakeState {
  final bool initiator;
  final SymmetricState ss;

  /// Local static keypair (always present for IK).
  final Uint8List sPub;
  final Uint8List sPriv;

  /// Ephemeral keypair — generated on demand in `writeMessage` when the `e` token fires.
  Uint8List? ePub;
  Uint8List? ePriv;

  /// Remote static public key. Set by IK pre-message for initiator; learned
  /// in message 1 for responder.
  Uint8List? rs;

  /// Remote ephemeral public key. Learned in messages for both sides.
  Uint8List? re;

  /// Test-only ephemeral keypair overrides. When set, `_writeInitiatorMsg1`
  /// and `_writeResponderMsg2` use these instead of generating random ones.
  /// See [HandshakeState.initialize] for warnings.
  Uint8List? _testOnlyEphemeralPriv;
  Uint8List? _testOnlyEphemeralPub;

  /// Handshake complete; both `writeMessage` and `readMessage` return a
  /// `NoiseSplit` alongside the wire bytes.
  bool _finished = false;

  HandshakeState._({
    required this.initiator,
    required this.ss,
    required this.sPub,
    required this.sPriv,
    this.rs,
  });

  /// Initialize a fresh IK handshake.
  ///
  /// Precondition: `initiator == true` implies `remoteStaticPub` is provided
  /// (IK requires pre-message static). `initiator == false` implies it is NOT
  /// provided (we'll learn it from message 1).
  ///
  /// Prologue defaults to the Shepaw ACP v2 string.
  ///
  /// `ephemeralForTesting` lets tests inject a specific ephemeral keypair
  /// instead of generating a random one. Production code must never pass
  /// this — non-random ephemerals completely defeat Noise's forward secrecy.
  /// Used only by the cross-language interop test to prove transport keys
  /// match byte-for-byte with the TS side.
  static Future<HandshakeState> initialize({
    required bool initiator,
    required Uint8List staticPublicKey,
    required Uint8List staticPrivateKey,
    Uint8List? remoteStaticPublicKey,
    List<int>? prologue,
    ({Uint8List privateKey, Uint8List publicKey})? ephemeralForTesting,
  }) async {
    if (staticPublicKey.length != noiseDhLen || staticPrivateKey.length != noiseDhLen) {
      throw ArgumentError('static keypair must be $noiseDhLen bytes each');
    }
    if (initiator && (remoteStaticPublicKey == null || remoteStaticPublicKey.length != noiseDhLen)) {
      throw ArgumentError('IK initiator requires a 32-byte remoteStaticPublicKey');
    }
    if (!initiator && remoteStaticPublicKey != null) {
      throw ArgumentError('IK responder must not pre-set remoteStaticPublicKey');
    }

    final protocolNameBytes = Uint8List.fromList(noiseProtocolName.codeUnits);
    final ss = await SymmetricState.initialize(protocolNameBytes);

    // Mix in the prologue.
    await ss.mixHash(prologue ?? noisePrologueDefault);

    // IK pre-message: responder static public key is pre-shared. Both sides
    // MixHash it here — they see the same bytes in the same order.
    //
    //   <- s
    //
    // On the initiator we have `remoteStaticPublicKey`; on the responder we
    // have our own `staticPublicKey`. MixHash that.
    final rsForHash = initiator ? remoteStaticPublicKey! : staticPublicKey;
    await ss.mixHash(rsForHash);

    final hs = HandshakeState._(
      initiator: initiator,
      ss: ss,
      sPub: staticPublicKey,
      sPriv: staticPrivateKey,
      rs: initiator ? remoteStaticPublicKey : null,
    );
    if (ephemeralForTesting != null) {
      hs._testOnlyEphemeralPriv = ephemeralForTesting.privateKey;
      hs._testOnlyEphemeralPub = ephemeralForTesting.publicKey;
    }
    return hs;
  }

  bool get finished => _finished;

  /// After message 1 has been processed on the responder, the initiator's
  /// static public key is known; returns it. Returns null on the initiator
  /// side (it already knows `rs` from init).
  Uint8List? get remoteStaticPublicKey => rs;

  // ── Message construction ───────────────────────────────────────────────

  /// Write a handshake message. Advances internal state.
  /// `payload` is the Noise-level payload (may be empty).
  /// Returns `(bytesToSend, split?)` — `split` is non-null only once the
  /// handshake completes (on the IK responder's second message).
  Future<({Uint8List message, NoiseSplit? split})> writeMessage(List<int> payload) async {
    if (_finished) {
      throw NoiseHandshakeError('writeMessage called after handshake finished');
    }
    // Determine which pattern step we're on by looking at what's been set.
    if (initiator && ePub == null) {
      // Initiator's first message: -> e, es, s, ss
      return _writeInitiatorMsg1(payload);
    }
    if (!initiator && ePub == null) {
      // Responder writing msg 2: <- e, ee, se.
      // Valid only after we've already consumed msg 1 (so `re` must be set).
      if (re == null) {
        throw NoiseHandshakeError('responder cannot writeMessage before reading msg 1');
      }
      return _writeResponderMsg2(payload);
    }
    throw NoiseHandshakeError(
      'writeMessage called in an unexpected phase (initiator=$initiator, ePub set=${ePub != null})',
    );
  }

  /// Read a handshake message. Mirrors `writeMessage` from the other side.
  Future<({Uint8List payload, NoiseSplit? split})> readMessage(List<int> message) async {
    if (_finished) {
      throw NoiseHandshakeError('readMessage called after handshake finished');
    }
    if (!initiator && re == null) {
      // Responder reading msg 1: consume -> e, es, s, ss
      return _readResponderMsg1(message);
    }
    if (initiator && re == null) {
      // Initiator reading msg 2: consume <- e, ee, se
      return _readInitiatorMsg2(message);
    }
    throw NoiseHandshakeError(
      'readMessage called in an unexpected phase (initiator=$initiator, re set=${re != null})',
    );
  }

  // ── Message 1 (initiator → responder): -> e, es, s, ss ────────────────

  Future<({Uint8List message, NoiseSplit? split})> _writeInitiatorMsg1(List<int> payload) async {
    // e: generate ephemeral, MixHash(e.pub), send e.pub as plaintext prefix.
    final eKeys = _testOnlyEphemeralPriv != null
        ? (privateKey: _testOnlyEphemeralPriv!, publicKey: _testOnlyEphemeralPub!)
        : await noiseGenerateKeyPair();
    ePriv = eKeys.privateKey;
    ePub = eKeys.publicKey;
    await ss.mixHash(ePub!);

    // es: MixKey(DH(e, rs))
    final es = await noiseDh(privateKey: ePriv!, remotePublicKey: rs!);
    await ss.mixKey(es);

    // s: EncryptAndHash(s.pub) — ciphertext (32 + 16 bytes if keyed)
    final sCipher = await ss.encryptAndHash(sPub);

    // ss: MixKey(DH(s, rs))
    final ssDh = await noiseDh(privateKey: sPriv, remotePublicKey: rs!);
    await ss.mixKey(ssDh);

    // Payload: EncryptAndHash(payload)
    final payloadCipher = await ss.encryptAndHash(payload);

    // Wire: e.pub || sCipher || payloadCipher
    final out = Uint8List(noiseDhLen + sCipher.length + payloadCipher.length);
    out.setRange(0, noiseDhLen, ePub!);
    out.setRange(noiseDhLen, noiseDhLen + sCipher.length, sCipher);
    out.setRange(noiseDhLen + sCipher.length, out.length, payloadCipher);

    return (message: out, split: null);
  }

  Future<({Uint8List payload, NoiseSplit? split})> _readResponderMsg1(List<int> message) async {
    // Message layout: e.pub (32) || encrypted-s (32 + 16 = 48) || encrypted-payload
    const minMsg1Len = noiseDhLen + (noiseDhLen + noiseTagLen); // 80
    if (message.length < minMsg1Len) {
      throw NoiseHandshakeError('msg1 too short (${message.length} < $minMsg1Len)');
    }

    // e: read e.pub, MixHash(e.pub)
    re = Uint8List.fromList(message.sublist(0, noiseDhLen));
    await ss.mixHash(re!);

    // es: MixKey(DH(s, e_remote))
    final es = await noiseDh(privateKey: sPriv, remotePublicKey: re!);
    await ss.mixKey(es);

    // s: DecryptAndHash(encrypted-s) → 32-byte peer static public key
    const sCipherLen = noiseDhLen + noiseTagLen;
    final encryptedS = message.sublist(noiseDhLen, noiseDhLen + sCipherLen);
    final decryptedS = await ss.decryptAndHash(encryptedS);
    if (decryptedS.length != noiseDhLen) {
      throw NoiseHandshakeError(
        'decrypted remote static has unexpected length ${decryptedS.length}',
      );
    }
    rs = decryptedS;

    // ss: MixKey(DH(s, rs))
    final ssDh = await noiseDh(privateKey: sPriv, remotePublicKey: rs!);
    await ss.mixKey(ssDh);

    // Payload: DecryptAndHash(payload-cipher)
    final encryptedPayload = message.sublist(noiseDhLen + sCipherLen);
    final payload = await ss.decryptAndHash(encryptedPayload);

    return (payload: payload, split: null);
  }

  // ── Message 2 (responder → initiator): <- e, ee, se ────────────────────

  Future<({Uint8List message, NoiseSplit? split})> _writeResponderMsg2(List<int> payload) async {
    // e: generate ephemeral, MixHash(e.pub), send it as plaintext prefix.
    final eKeys = _testOnlyEphemeralPriv != null
        ? (privateKey: _testOnlyEphemeralPriv!, publicKey: _testOnlyEphemeralPub!)
        : await noiseGenerateKeyPair();
    ePriv = eKeys.privateKey;
    ePub = eKeys.publicKey;
    await ss.mixHash(ePub!);

    // ee: MixKey(DH(e, re))
    final ee = await noiseDh(privateKey: ePriv!, remotePublicKey: re!);
    await ss.mixKey(ee);

    // se: MixKey(DH(s, re)) — responder's static DH with initiator's ephemeral
    // Note the token ordering matters: for responder writing, `se` means
    // DH(s_local, e_remote). The spec's rule is "first token letter names the
    // local contribution; second letter names the remote contribution".
    final se = await noiseDh(privateKey: sPriv, remotePublicKey: re!);
    await ss.mixKey(se);

    // Payload: EncryptAndHash(payload)
    final payloadCipher = await ss.encryptAndHash(payload);

    // Wire: e.pub || payloadCipher
    final out = Uint8List(noiseDhLen + payloadCipher.length);
    out.setRange(0, noiseDhLen, ePub!);
    out.setRange(noiseDhLen, out.length, payloadCipher);

    final split = await _splitFromSymmetric();
    _finished = true;
    return (message: out, split: split);
  }

  Future<({Uint8List payload, NoiseSplit? split})> _readInitiatorMsg2(List<int> message) async {
    if (message.length < noiseDhLen) {
      throw NoiseHandshakeError('msg2 too short (${message.length} < $noiseDhLen)');
    }

    // e: read remote ephemeral, MixHash(re)
    re = Uint8List.fromList(message.sublist(0, noiseDhLen));
    await ss.mixHash(re!);

    // ee: MixKey(DH(e_local, re))
    final ee = await noiseDh(privateKey: ePriv!, remotePublicKey: re!);
    await ss.mixKey(ee);

    // se: MixKey(DH(e_local, rs)) — mirror of responder's `se` which was
    // DH(s_remote, e_local). Wait — reread the spec.
    //
    // Token order per Noise §7.1: the token letters are [local][remote]
    // FROM THE WRITER'S PERSPECTIVE. When the responder writes `se`, it
    // means DH(s_local_to_responder, e_remote_to_responder) = DH(s_resp, e_init).
    // When the initiator READS `se`, it performs the same DH from its side,
    // which is DH(e_init, s_resp) — mathematically equal to what the
    // responder computed because DH is commutative.
    //
    // So reading `se` on initiator = DH(e_local=e_init, rs=s_resp).
    final se = await noiseDh(privateKey: ePriv!, remotePublicKey: rs!);
    await ss.mixKey(se);

    // Payload
    final encryptedPayload = message.sublist(noiseDhLen);
    final payload = await ss.decryptAndHash(encryptedPayload);

    final split = await _splitFromSymmetric();
    _finished = true;
    return (payload: payload, split: split);
  }

  Future<NoiseSplit> _splitFromSymmetric() async {
    final s = await ss.split();
    return NoiseSplit(c1Key: s.c1Key, c2Key: s.c2Key);
  }
}
