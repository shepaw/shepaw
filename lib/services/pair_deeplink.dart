/// Parses the `shepaw://pair?url=<WS URL>&code=<pairing code>` deep-link
/// embedded in enrollment QR codes, as produced by the gateway CLIs'
/// `enroll --base-url` and by `shepaw-hub pair`.
///
/// Format (URL-encoded values, so inner `?`/`&`/`#` survive transport):
///
///     shepaw://pair?url=<urlencoded WS URL incl. `?agentId=...#fp=...`>
///                 &code=<urlencoded 9-char pairing code>
///
/// The parser is strict: missing fields, wrong scheme, non-WS URL, or
/// malformed code all throw `PairDeeplinkError` with a user-facing message.
/// Callers (the scanner screen) turn that into a SnackBar and keep the
/// camera running so the user can try another QR without re-opening.
///
/// We deliberately do NOT validate the code charset here — that's the
/// agent's job, and the app has no ground truth for which chars are in
/// the rotating alphabet. We just check the shape (non-empty, < 64 chars
/// to bound payload size) and pass through.
library;

/// The canonical deep-link scheme the gateway CLI prints into QRs.
const String pairDeeplinkScheme = 'shepaw';
const String pairDeeplinkHost = 'pair';

/// Result of parsing a valid `shepaw://pair?...` URI.
class PairDeeplink {
  const PairDeeplink({required this.wsUrl, required this.code});

  /// The WebSocket URL the app should connect to. Already URL-decoded.
  /// Guaranteed to start with `ws://` or `wss://`.
  final String wsUrl;

  /// The pairing code. URL-decoded, but NOT normalized (kept verbatim so
  /// the Noise msg 1 payload carries exactly what the user's QR said).
  final String code;

  @override
  String toString() => 'PairDeeplink(wsUrl: $wsUrl, code: $code)';
}

/// Thrown when a scanned string isn't a valid shepaw pairing deep-link.
/// The `message` is suitable for showing the user directly — it's already
/// phrased as "what you scanned isn't a pairing code".
class PairDeeplinkError implements Exception {
  const PairDeeplinkError(this.message);
  final String message;

  @override
  String toString() => 'PairDeeplinkError: $message';
}

/// Parse a raw string (the QR payload) into a `PairDeeplink`. Throws
/// `PairDeeplinkError` on any malformed input.
///
/// The parsing is intentionally permissive about casing on the scheme and
/// host (`Uri.parse` lowercases them) but strict on everything else — we'd
/// rather reject a slightly-wrong QR than silently connect to the wrong
/// agent.
PairDeeplink parsePairDeeplink(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw const PairDeeplinkError('二维码内容为空。');
  }

  Uri uri;
  try {
    uri = Uri.parse(trimmed);
  } catch (_) {
    throw PairDeeplinkError('二维码不是合法的 URI：\n${_truncate(trimmed)}');
  }

  if (uri.scheme != pairDeeplinkScheme) {
    throw PairDeeplinkError(
      '这不是 Shepaw 配对二维码（scheme 是 "${uri.scheme}"，应为 "shepaw://"）。',
    );
  }
  if (uri.host != pairDeeplinkHost) {
    throw PairDeeplinkError(
      '不支持的 Shepaw 链接类型 "$uri"，预期 "shepaw://pair?..."。',
    );
  }

  final params = uri.queryParameters;
  final url = params['url'];
  final code = params['code'];

  if (url == null || url.isEmpty) {
    throw const PairDeeplinkError(
      '配对链接缺少 url 参数。重新在 agent 主机运行 `<gateway> enroll` 生成新二维码。',
    );
  }
  if (code == null || code.isEmpty) {
    throw const PairDeeplinkError(
      '配对链接缺少 code 参数。重新在 agent 主机运行 `<gateway> enroll` 生成新二维码。',
    );
  }

  // The CLI encoded these via encodeURIComponent; Uri.queryParameters has
  // already decoded them for us. Sanity-check the WS URL shape — if the
  // operator printed something like `http://...` by accident, fail loudly
  // here rather than at Noise-handshake time.
  if (!(url.startsWith('ws://') || url.startsWith('wss://'))) {
    throw PairDeeplinkError(
      '链接中的 url 不是 WebSocket 地址（$url）。QR 可能损坏或被改过。',
    );
  }

  // Code length bound — the server normalizes input to 9 alphabet chars,
  // and the CLI prints exactly that. Anything radically larger is either
  // an error or an attempt to pad a malicious payload. 64 is very generous.
  if (code.length > 64) {
    throw const PairDeeplinkError(
      '配对码异常（过长）。重新生成二维码。',
    );
  }

  return PairDeeplink(wsUrl: url, code: code);
}

/// Build a canonical `shepaw://pair?url=...&code=...` URL. Used by tests
/// and (eventually) by the app if it ever wants to re-export a pairing.
/// Keeping this next to the parser guarantees round-trip fidelity.
String buildPairDeeplink({required String wsUrl, required String code}) {
  final query = <String, String>{
    'url': wsUrl,
    'code': code,
  };
  final uri = Uri(
    scheme: pairDeeplinkScheme,
    host: pairDeeplinkHost,
    queryParameters: query,
  );
  return uri.toString();
}

String _truncate(String s, [int max = 80]) {
  if (s.length <= max) return s;
  return '${s.substring(0, max)}…';
}
