/// ACP v2 wire-envelope codec (Flutter / Dart side).
///
/// Byte-for-byte compatible with the TypeScript SDK's `src/envelope.ts`.
/// Every WebSocket text frame between the Shepaw app and the ACP agent is a
/// JSON object of the shape:
///
///     {"v": 2, "t": "hs" | "data" | "err", "p": "<base64url>"}
///
/// - `v` — protocol version, must be `2`
/// - `t` — frame type (handshake / data / error)
/// - `p` — base64url payload, no padding
///
/// The Dart side enforces the same size limits and rejection rules the TS
/// side enforces. When those numbers change, update both files.
library;

import 'dart:convert';
import 'dart:typed_data';

// ── Constants ─────────────────────────────────────────────────────────────

const int protocolVersion = 2;

/// Max payload bytes on the app→agent direction.
const int maxFrameAppToAgent = 256 * 1024;

/// Max payload bytes on the agent→app direction.
const int maxFrameAgentToApp = 4 * 1024 * 1024;

/// Hard cap on cumulative bytes received before the handshake completes.
const int maxPrehandshakeBytes = 16 * 1024;

/// WebSocket close codes used by the v2 protocol layer. Must match the TS
/// side's `WS_CLOSE` object exactly.
class WsClose {
  static const int unsupportedVersion = 4400;
  static const int unsupportedType = 4401;
  static const int frameTooLarge = 4402;
  static const int fingerprintMismatch = 4403;
  static const int agentIdMismatch = 4404;
  static const int unexpectedHsAfterReady = 4407;
  static const int unexpectedDataBeforeReady = 4406;
  static const int handshakeTimeout = 4408;
  static const int handshakeFailed = 4409;
  static const int malformedFrame = 4410;
}

// ── Types ─────────────────────────────────────────────────────────────────

enum FrameType { hs, data, err }

class Frame {
  final FrameType t;
  final Uint8List payload;
  const Frame({required this.t, required this.payload});
}

/// Thrown by [decodeFrame]. `closeCode` tells the WS glue which 44xx to use.
class EnvelopeError implements Exception {
  final String code;
  final int closeCode;
  final String message;
  EnvelopeError(this.code, this.closeCode, this.message);
  @override
  String toString() => 'EnvelopeError($code): $message';
}

// ── Encode ────────────────────────────────────────────────────────────────

/// Encode a [Frame] to the on-wire JSON string.
String encodeFrame(Frame frame) {
  final obj = <String, dynamic>{
    'v': protocolVersion,
    't': _frameTypeToString(frame.t),
    'p': toBase64Url(frame.payload),
  };
  return jsonEncode(obj);
}

// ── Decode ────────────────────────────────────────────────────────────────

/// Decode an on-wire JSON string into a [Frame].
///
/// `maxPayload` defaults to the agent→app limit (4 MiB). App-side code with a
/// tighter cap (256 KiB) should pass [maxFrameAppToAgent] explicitly.
Frame decodeFrame(String raw, {int maxPayload = maxFrameAgentToApp}) {
  dynamic parsed;
  try {
    parsed = jsonDecode(raw);
  } catch (_) {
    throw EnvelopeError('MALFORMED_FRAME', WsClose.malformedFrame, 'not valid JSON');
  }

  if (parsed is! Map<String, dynamic>) {
    throw EnvelopeError('MALFORMED_FRAME', WsClose.malformedFrame, 'frame must be a JSON object');
  }

  final v = parsed['v'];
  if (v != protocolVersion) {
    throw EnvelopeError(
      'UNSUPPORTED_VERSION',
      WsClose.unsupportedVersion,
      'expected version $protocolVersion, got $v',
    );
  }

  final tStr = parsed['t'];
  final t = _stringToFrameType(tStr);
  if (t == null) {
    throw EnvelopeError(
      'UNSUPPORTED_TYPE',
      WsClose.unsupportedType,
      'unknown frame type: $tStr',
    );
  }

  final p = parsed['p'];
  if (p is! String) {
    throw EnvelopeError(
      'MALFORMED_FRAME',
      WsClose.malformedFrame,
      "frame field 'p' must be a base64url string",
    );
  }

  Uint8List payload;
  try {
    payload = fromBase64Url(p);
  } on FormatException catch (e) {
    throw EnvelopeError(
      'MALFORMED_FRAME',
      WsClose.malformedFrame,
      'payload is not valid base64url: ${e.message}',
    );
  }

  if (payload.length > maxPayload) {
    throw EnvelopeError(
      'FRAME_TOO_LARGE',
      WsClose.frameTooLarge,
      'payload ${payload.length} bytes exceeds limit $maxPayload',
    );
  }

  return Frame(t: t, payload: payload);
}

// ── Base64url ─────────────────────────────────────────────────────────────

/// Encode raw bytes to unpadded base64url.
String toBase64Url(List<int> bytes) {
  // Dart's base64Url encoder emits padding; strip it.
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Decode unpadded or padded base64url.
/// Rejects strings containing standard-base64 characters (`+` or `/`).
Uint8List fromBase64Url(String s) {
  if (s.contains('+') || s.contains('/')) {
    throw const FormatException("standard-base64 characters ('+'/'/') are not allowed");
  }
  // `base64Url.decode` requires padding; pad on input.
  final mod = s.length % 4;
  final padded = mod == 0 ? s : '$s${'=' * (4 - mod)}';
  late Uint8List bytes;
  try {
    bytes = base64Url.decode(padded);
  } on FormatException {
    rethrow;
  }
  // Roundtrip check — Dart's decoder is strict, but keep this as a belt-and-
  // suspenders so future library changes can't let malformed base64 through.
  final reencoded = base64Url.encode(bytes).replaceAll('=', '');
  final normalized = s.replaceAll(RegExp(r'=+$'), '');
  if (normalized != reencoded) {
    throw const FormatException('input contains non-base64url characters');
  }
  return bytes;
}

// ── Helpers ───────────────────────────────────────────────────────────────

String _frameTypeToString(FrameType t) {
  switch (t) {
    case FrameType.hs:
      return 'hs';
    case FrameType.data:
      return 'data';
    case FrameType.err:
      return 'err';
  }
}

FrameType? _stringToFrameType(Object? s) {
  if (s is! String) return null;
  switch (s) {
    case 'hs':
      return FrameType.hs;
    case 'data':
      return FrameType.data;
    case 'err':
      return FrameType.err;
    default:
      return null;
  }
}
