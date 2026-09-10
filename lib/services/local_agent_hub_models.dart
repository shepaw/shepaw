import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'noise/noise_envelope.dart';

/// Default loopback URL of `shepaw-hub web`.
const kLocalAgentHubDashboardUrl = 'http://127.0.0.1:4000';

/// npm package that provides the `shepaw-hub` binary.
const kLocalAgentHubNpmPackage = 'shepaw-agent-hub';

/// How long to hide the desktop prompt after the user taps “later”.
const kLocalAgentHubSnooze = Duration(days: 3);

enum LocalHubPresence {
  /// No CLI, no config dir, dashboard not responding.
  missing,

  /// CLI or `~/.config/shepaw-hub` exists, but the dashboard is down.
  installed,

  /// Dashboard `/api/health` returned ok.
  running,
}

class LocalHubDetection {
  const LocalHubDetection({
    required this.presence,
    this.alreadyPaired = false,
    this.dashboardAuthRequired = false,
    this.instanceCount,
    this.hubFingerprint,
    this.hubBinary,
    this.nodeAvailable = false,
  });

  final LocalHubPresence presence;
  final bool alreadyPaired;
  final bool dashboardAuthRequired;
  final int? instanceCount;
  final String? hubFingerprint;
  final String? hubBinary;
  final bool nodeAvailable;

  bool get isPresent =>
      presence == LocalHubPresence.installed ||
      presence == LocalHubPresence.running;
}

class LocalHubPairTicket {
  const LocalHubPairTicket({
    required this.qrPayload,
    required this.fingerprint,
    this.localEndpoint,
  });

  final String qrPayload;
  final String fingerprint;
  final String? localEndpoint;
}

class LocalHubException implements Exception {
  LocalHubException(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => message;
}

/// Rewrite a hub QR `local` WS URL to loopback when it points at this machine.
String preferLoopbackIfLocal(String endpoint, Set<String> localIpv4s) {
  final uri = Uri.tryParse(endpoint);
  if (uri == null || uri.host.isEmpty) return endpoint;
  final host = uri.host;
  if (host == '127.0.0.1' || host == 'localhost' || host == '::1') {
    return endpoint;
  }
  if (localIpv4s.contains(host)) {
    return uri.replace(host: '127.0.0.1').toString();
  }
  return endpoint;
}

bool parseDashboardHealthOk(String body) {
  try {
    final data = jsonDecode(body);
    if (data is Map<String, dynamic>) {
      return data['ok'] == true;
    }
  } catch (_) {}
  return false;
}

bool parseDashboardAuthRequired(String body) {
  try {
    final data = jsonDecode(body);
    if (data is Map<String, dynamic>) {
      return data['authRequired'] == true;
    }
  } catch (_) {}
  return false;
}

LocalHubPairTicket? parsePairTicket(Object json) {
  if (json is! Map) return null;
  final qr = json['qrPayload'] as String? ?? json['qr_payload'] as String?;
  final fp = json['fingerprint'] as String?;
  if (qr == null || qr.isEmpty || fp == null || fp.isEmpty) return null;
  return LocalHubPairTicket(
    qrPayload: qr,
    fingerprint: fp,
    localEndpoint: json['localEndpoint'] as String? ?? json['local_endpoint'] as String?,
  );
}

int? parseInstanceCount(Object json) {
  if (json is List) return json.length;
  if (json is Map && json['instances'] is List) {
    return (json['instances'] as List).length;
  }
  return null;
}

/// SHA-256 fingerprint (16 hex) matching agent-bridge / NoiseIdentity.
String fingerprintFromPublicKey(Uint8List publicKey) {
  final digest = crypto.sha256.convert(publicKey).bytes;
  final sb = StringBuffer();
  for (var i = 0; i < 8; i++) {
    sb.write(digest[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Read the hub peer identity file (`peer-identity.json`) without touching the private key beyond parse.
String? fingerprintFromIdentityJson(String raw) {
  try {
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic>) return null;
    final encoded = data['staticPublicKey'] as String?;
    if (encoded == null || encoded.isEmpty) return null;
    final pub = fromBase64Url(encoded);
    if (pub.length != 32) return null;
    return fingerprintFromPublicKey(pub);
  } catch (_) {
    return null;
  }
}

/// Node ≥ 18.17 is required by shepaw-agent-hub.
bool nodeVersionMeetsHub(String versionOutput) {
  final m = RegExp(r'v?(\d+)\.(\d+)').firstMatch(versionOutput.trim());
  if (m == null) return false;
  final major = int.parse(m.group(1)!);
  final minor = int.parse(m.group(2)!);
  return major > 18 || (major == 18 && minor >= 17);
}

String joinPathSegments(List<String> parts, {required bool windows}) {
  final sep = windows ? '\\' : '/';
  return parts.where((p) => p.isNotEmpty).join(sep);
}

/// Prepend extra dirs that exist so GUI apps (thin PATH) can still find nvm/Homebrew binaries.
String augmentPath(String existing, Iterable<String> extraDirs, {required bool windows}) {
  final sep = windows ? ';' : ':';
  final seen = <String>{};
  final out = <String>[];
  void add(String raw) {
    final p = raw.trim();
    if (p.isEmpty) return;
    final key = windows ? p.toLowerCase() : p;
    if (!seen.add(key)) return;
    out.add(p);
  }

  for (final d in extraDirs) {
    add(d);
  }
  for (final d in existing.split(sep)) {
    add(d);
  }
  return out.join(sep);
}
