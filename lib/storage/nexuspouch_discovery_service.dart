import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

/// A Nexuspouch node discovered via mDNS (`_nexuspouch._tcp.local`).
class DiscoveredNexuspouch {
  final String name;
  final String fingerprint;
  final String host;
  final int port;
  final String endpoint;
  final String path;

  const DiscoveredNexuspouch({
    required this.name,
    required this.fingerprint,
    required this.host,
    required this.port,
    required this.endpoint,
    required this.path,
  });

  String get shortFp =>
      fingerprint.length > 8 ? '${fingerprint.substring(0, 8)}…' : fingerprint;
}

/// Browses LAN for Nexuspouch store masters advertised over mDNS.
///
/// First Noise pairing still requires QR (`code` + `pk`); discovery only
/// surfaces already-running nodes and refreshes `localEndpoint` for paired peers.
class NexuspouchDiscoveryService {
  NexuspouchDiscoveryService._();
  static final instance = NexuspouchDiscoveryService._();

  static const serviceType = '_nexuspouch._tcp.local';

  final _controller =
      StreamController<List<DiscoveredNexuspouch>>.broadcast();

  List<DiscoveredNexuspouch> _latest = const [];
  bool _scanning = false;

  Stream<List<DiscoveredNexuspouch>> get stream => _controller.stream;
  List<DiscoveredNexuspouch> get latest => _latest;
  bool get scanning => _scanning;

  /// One-shot browse (default ~3s). Emits intermediate + final lists on [stream].
  Future<List<DiscoveredNexuspouch>> browse({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (_scanning) return _latest;
    _scanning = true;
    final found = <String, DiscoveredNexuspouch>{};

    void publish() {
      final list = found.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      _latest = list;
      if (!_controller.isClosed) _controller.add(list);
    }

    publish();

    final client = MDnsClient(
      rawDatagramSocketFactory: (
        dynamic host,
        int port, {
        bool reuseAddress = false,
        bool reusePort = false,
        int ttl = 1,
      }) {
        return RawDatagramSocket.bind(
          host,
          port,
          reuseAddress: true,
          reusePort: Platform.isIOS || reusePort,
          ttl: ttl,
        );
      },
    ); // bind returns Future — matches RawDatagramSocketFactory
    try {
      await client.start();
      final deadline = DateTime.now().add(timeout);
      await for (final ptr in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(serviceType),
        timeout: timeout,
      )) {
        if (DateTime.now().isAfter(deadline)) break;
        await for (final srv in client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
          timeout: const Duration(seconds: 2),
        )) {
          String? fp;
          String? name;
          var path = '/peer/ws';
          await for (final txt in client.lookup<TxtResourceRecord>(
            ResourceRecordQuery.text(ptr.domainName),
            timeout: const Duration(seconds: 1),
          )) {
            final props = _parseTxt(txt.text);
            fp = props['fp'] ?? fp;
            name = props['name'] ?? name;
            final p = props['path'];
            if (p != null && p.isNotEmpty) {
              path = p.startsWith('/') ? p : '/$p';
            }
          }

          String? ip;
          await for (final a in client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target),
            timeout: const Duration(seconds: 1),
          )) {
            ip = a.address.address;
            break;
          }
          if (ip == null) {
            await for (final a in client.lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv6(srv.target),
              timeout: const Duration(seconds: 1),
            )) {
              ip = a.address.address;
              break;
            }
          }
          if (ip == null || srv.port <= 0) continue;

          final host = ip.contains(':') ? '[$ip]' : ip;
          final endpoint = 'ws://$host:${srv.port}$path';
          final instanceName = ptr.domainName.split('.').first;
          final peer = DiscoveredNexuspouch(
            name: (name != null && name.isNotEmpty) ? name : instanceName,
            fingerprint: (fp != null && fp.isNotEmpty) ? fp : '',
            host: ip,
            port: srv.port,
            endpoint: endpoint,
            path: path,
          );
          final key = peer.fingerprint.isNotEmpty
              ? peer.fingerprint
              : peer.endpoint;
          found[key] = peer;
          publish();
        }
      }
    } catch (_) {
      // Browse is best-effort (permissions / no multicast).
    } finally {
      client.stop();
      _scanning = false;
      publish();
    }
    return _latest;
  }

  void dispose() {
    unawaited(_controller.close());
  }
}

/// Parse DNS-SD TXT payload into key/value map.
///
/// `multicast_dns` exposes TXT as one [String]; properties may be joined with
/// NULs or appear as sequential `key=value` tokens.
Map<String, String> _parseTxt(String raw) {
  final out = <String, String>{};
  final parts = raw.split(RegExp(r'[\x00\n\r]+'));
  for (final part in parts) {
    final eq = part.indexOf('=');
    if (eq > 0) {
      out[part.substring(0, eq)] = part.substring(eq + 1);
      continue;
    }
  }
  // Fallback: scan for known keys if separators were stripped.
  for (final key in ['fp', 'name', 'path', 'proto']) {
    if (out.containsKey(key)) continue;
    final re = RegExp('$key=([^\\x00\\s]+)');
    final m = re.firstMatch(raw);
    if (m != null) out[key] = m.group(1)!;
  }
  return out;
}
