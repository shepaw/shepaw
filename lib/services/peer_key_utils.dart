/// Utility for decoding the cached peer static public key stored in
/// `RemoteAgent.metadata['cached_peer_static_public_key']` (base64 string)
/// into the `Uint8List` expected by `ACPAgentConnection.connect()`.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Decode the base64-encoded peer static public key from agent metadata.
///
/// Returns `null` if [value] is null, empty, or not a valid base64 string,
/// so callers can pass the result directly to `cachedPeerStaticPublicKey:`.
Uint8List? decodeCachedPeerPublicKey(dynamic value) {
  if (value == null) return null;
  final str = value.toString();
  if (str.isEmpty) return null;
  try {
    return base64Decode(str);
  } catch (_) {
    return null;
  }
}
