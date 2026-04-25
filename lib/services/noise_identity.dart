/// Noise Protocol long-term identity (X25519 static keypair) for this Shepaw install.
///
/// Generated once on first use, persisted via [SecureKeyManager] under
/// [NoiseIdentity.storageKey], and re-used for every subsequent connection.
///
/// Will be consumed by the ACP Noise IK handshake (v2 wire protocol). This file
/// ships ahead of the handshake wiring so the keypair exists before any
/// connection path starts relying on it — symmetric with the agent SDK's
/// `identity.ts` / `identity.json` land-first rollout.
///
/// Storage layout (value stored under `storageKey`):
///
///   v1.<base64 private key (32 bytes)>.<base64 public key (32 bytes)>
///
/// The `v1` prefix lets a future v2 format be detected cleanly. The private
/// and public halves are stored side-by-side so we can load without recomputing
/// the public key from the private scalar on every boot.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto_hash;
import 'package:cryptography/cryptography.dart';

import 'logger_service.dart';
import 'secure_key_manager.dart';

class NoiseIdentity {
  /// Raw 32-byte X25519 public key.
  final Uint8List publicKey;

  /// Raw 32-byte X25519 private key.
  final Uint8List privateKey;

  /// When this keypair was first created (ms since epoch, UTC). Null when the
  /// record was migrated from an older storage format that didn't track it.
  final int? createdAtMs;

  const NoiseIdentity._({
    required this.publicKey,
    required this.privateKey,
    required this.createdAtMs,
  });

  /// Secure-storage key under which the identity record is persisted.
  ///
  /// `.v1` in the name is a deliberate safety rail: if we ever need to change
  /// the format we'll bump the storage key rather than risk mis-parsing the
  /// old one.
  static const String storageKey = 'shepaw.noise.static.v1';

  /// Cache so we don't hit secure storage on every call. `connect()` runs
  /// per agent; reading the file once per process is enough.
  static NoiseIdentity? _cached;

  /// Load the identity, or generate+persist a fresh one on first use.
  ///
  /// Safe to call concurrently only after a first serialized call has
  /// completed; the current call sites (app startup + connect) are sequential
  /// in practice, so no mutex is wired in.
  static Future<NoiseIdentity> loadOrCreate() async {
    final cached = _cached;
    if (cached != null) return cached;

    final existing = await SecureKeyManager.getSecureValue(storageKey);
    if (existing != null && existing.isNotEmpty) {
      try {
        final parsed = _parseRecord(existing);
        _cached = parsed;
        return parsed;
      } catch (e, st) {
        // Corrupt record — do NOT silently regenerate, because that would
        // orphan any agents paired to the old key. Surface loudly and let
        // the user decide to wipe & re-pair.
        LoggerService().error(
          'Noise identity storage record is corrupt; refusing to overwrite. '
          'If this is a fresh install you can safely delete the `$storageKey` '
          'entry. Otherwise paired agents will need to be re-added.',
          tag: 'Noise',
          error: e,
          stackTrace: st,
        );
        rethrow;
      }
    }

    final fresh = await _generate();
    await SecureKeyManager.saveSecureValue(storageKey, _encodeRecord(fresh));
    _cached = fresh;
    LoggerService().info(
      'Generated new Noise identity (fingerprint ${fresh.fingerprintHex})',
      tag: 'Noise',
    );
    return fresh;
  }

  /// 16-hex short fingerprint: first 8 bytes of `sha256(publicKey)`. Matches
  /// the `#fp=…` URL fragment published by the agent SDK — use it to pin the
  /// peer static key.
  String get fingerprintHex {
    final digest = crypto_hash.sha256.convert(publicKey).bytes;
    final sb = StringBuffer();
    for (var i = 0; i < 8; i++) {
      sb.write(digest[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Base64-encoded public key. This is the string the user copies from the
  /// pairing screen and pastes into `<gateway> peers add <pubkey>` on the
  /// agent host — the v2.1 equivalent of "share the token".
  ///
  /// Standard base64 with padding; 32 bytes → 44 chars ending in `=`. The
  /// agent SDK's `addPeer` accepts this format directly.
  String get publicKeyBase64 => base64.encode(publicKey);

  /// Exposes the keypair in the form the `cryptography` package's X25519
  /// implementation expects. Created on demand because `SimpleKeyPairData`
  /// isn't trivially reusable across operations (it's data, not a handle,
  /// but keeping a live reference around forever is unnecessary).
  SimpleKeyPairData toCryptographyKeyPair() {
    return SimpleKeyPairData(
      privateKey,
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
  }

  // ── Testing / rotation helpers ──────────────────────────────────────────

  /// Clear both the in-memory cache and the persisted record. Primarily for
  /// tests; production call sites shouldn't need this — identity rotation is
  /// a user-facing "re-pair every agent" workflow and should go through a
  /// deliberate UI flow.
  @visibleForTestingOrRotation
  static Future<void> wipeForRotation() async {
    _cached = null;
    await SecureKeyManager.deleteSecureValue(storageKey);
  }

  /// Reset only the in-memory cache (tests).
  @visibleForTestingOrRotation
  static void resetCacheForTesting() {
    _cached = null;
  }

  // ── Internals ───────────────────────────────────────────────────────────

  static Future<NoiseIdentity> _generate() async {
    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    final privBytes = await keyPair.extractPrivateKeyBytes();
    final pub = await keyPair.extractPublicKey();
    if (privBytes.length != 32 || pub.bytes.length != 32) {
      throw StateError(
        'X25519 generated keypair with unexpected lengths: '
        'priv=${privBytes.length}, pub=${pub.bytes.length}',
      );
    }
    return NoiseIdentity._(
      publicKey: Uint8List.fromList(pub.bytes),
      privateKey: Uint8List.fromList(privBytes),
      createdAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  /// Construct from raw bytes. Visible for tests and for loading from storage.
  /// Validates lengths so callers don't have to.
  static NoiseIdentity fromRawBytes({
    required Uint8List publicKey,
    required Uint8List privateKey,
    int? createdAtMs,
  }) {
    if (publicKey.length != 32) {
      throw ArgumentError('publicKey must be 32 bytes, got ${publicKey.length}');
    }
    if (privateKey.length != 32) {
      throw ArgumentError('privateKey must be 32 bytes, got ${privateKey.length}');
    }
    return NoiseIdentity._(
      publicKey: publicKey,
      privateKey: privateKey,
      createdAtMs: createdAtMs,
    );
  }

  /// Encode for storage. Visible so a future "export identity" settings
  /// action can reuse the same format, and so tests can hit the encoder.
  String encodeRecord() => _encodeRecord(this);

  /// Parse a storage record. Visible for tests. Throws [FormatException] on
  /// malformed input.
  static NoiseIdentity parseRecord(String raw) => _parseRecord(raw);

  static String _encodeRecord(NoiseIdentity id) {
    final priv = base64.encode(id.privateKey);
    final pub = base64.encode(id.publicKey);
    final ts = id.createdAtMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    return 'v1.$priv.$pub.$ts';
  }

  static NoiseIdentity _parseRecord(String raw) {
    final parts = raw.split('.');
    // v1 has either 3 parts (legacy, no timestamp) or 4 parts (current).
    if (parts.isEmpty || parts[0] != 'v1') {
      throw FormatException('unknown record version prefix: ${parts.isEmpty ? "<empty>" : parts[0]}');
    }
    if (parts.length != 3 && parts.length != 4) {
      throw FormatException(
        'v1 record must have 3 or 4 dot-separated parts, got ${parts.length}',
      );
    }
    final priv = base64.decode(parts[1]);
    final pub = base64.decode(parts[2]);
    if (priv.length != 32) {
      throw FormatException('privateKey must be 32 bytes, got ${priv.length}');
    }
    if (pub.length != 32) {
      throw FormatException('publicKey must be 32 bytes, got ${pub.length}');
    }
    int? ts;
    if (parts.length == 4) {
      ts = int.tryParse(parts[3]);
      if (ts == null) {
        throw FormatException('invalid timestamp: ${parts[3]}');
      }
    }
    return NoiseIdentity._(
      publicKey: Uint8List.fromList(pub),
      privateKey: Uint8List.fromList(priv),
      createdAtMs: ts,
    );
  }
}

/// Annotation marker — used instead of `@visibleForTesting` so the intent is
/// clear when the same helper is legitimately called by a future "rotate my
/// identity" settings action. Currently a no-op; swap in
/// `meta.visibleForTesting` if linting requires it.
// ignore: library_private_types_in_public_api
const _VisibleForTestingOrRotation visibleForTestingOrRotation =
    _VisibleForTestingOrRotation();

class _VisibleForTestingOrRotation {
  const _VisibleForTestingOrRotation();
}
