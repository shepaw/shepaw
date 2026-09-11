import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shepaw/peer/models/pairing_payload.dart';
import 'package:shepaw/services/local_agent_hub_models.dart';
import 'package:shepaw/services/remote_hub_pairing_service.dart';

/// Fixed 32-byte key so the QR's `#fp=` always matches `sha256(pk)[:16]`.
final Uint8List _publicKey =
    Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
final String _fingerprint = fingerprintFromPublicKey(_publicKey);

String _qr({
  String local = 'ws://192.168.1.5:18793/peer/ws',
  String? name = 'Peer Book',
}) {
  return PeerPairingInfo.encode(
    localEndpoint: local,
    code: 'ABCD1234',
    fingerprint: _fingerprint,
    publicKey: _publicKey,
    name: name,
  );
}

const _dashboard = 'http://192.168.1.5:4000';

void main() {
  RemoteHubPairingService build(
    Future<http.Response> Function(http.Request request) handler, {
    Set<String> localIps = const {'127.0.0.1'},
  }) {
    return RemoteHubPairingService(
      httpClient: MockClient(handler),
      localIpv4s: () async => localIps,
    );
  }

  http.Response healthOk({bool authRequired = false}) => http.Response(
        jsonEncode({'ok': true, 'authRequired': authRequired}),
        200,
      );

  group('mintTicket — probe', () {
    test('transport failure is unreachable', () async {
      final svc = build((_) async => throw const SocketExceptionStub());
      await expectLater(
        svc.mintTicket(Uri.parse(_dashboard)),
        throwsA(
          isA<RemoteHubException>().having((e) => e.code, 'code', 'unreachable'),
        ),
      );
    });

    test('health responding but not a hub is not-hub', () async {
      final svc = build((_) async => http.Response('{"ok":false}', 200));
      await expectLater(
        svc.mintTicket(Uri.parse(_dashboard)),
        throwsA(
          isA<RemoteHubException>().having((e) => e.code, 'code', 'not-hub'),
        ),
      );
    });

    test('a plain non-JSON 200 is not-hub, not unreachable', () async {
      final svc = build((_) async => http.Response('<html>hi</html>', 200));
      await expectLater(
        svc.mintTicket(Uri.parse(_dashboard)),
        throwsA(
          isA<RemoteHubException>().having((e) => e.code, 'code', 'not-hub'),
        ),
      );
    });

    test('authRequired without a token is auth-required', () async {
      final svc = build((_) async => healthOk(authRequired: true));
      await expectLater(
        svc.mintTicket(Uri.parse(_dashboard)),
        throwsA(
          isA<RemoteHubException>()
              .having((e) => e.code, 'code', 'auth-required'),
        ),
      );
    });

    test('a blank token does not satisfy authRequired', () async {
      final svc = build((_) async => healthOk(authRequired: true));
      await expectLater(
        svc.mintTicket(Uri.parse(_dashboard), token: '   '),
        throwsA(
          isA<RemoteHubException>()
              .having((e) => e.code, 'code', 'auth-required'),
        ),
      );
    });
  });

  group('mintTicket — auth headers', () {
    test('no token means no Authorization header anywhere', () async {
      final seen = <http.Request>[];
      final svc = build((request) async {
        seen.add(request);
        if (request.url.path == '/api/health') return healthOk();
        if (request.url.path == '/api/peer/pair') {
          return http.Response(
            jsonEncode({'qrPayload': _qr(), 'fingerprint': _fingerprint}),
            201,
          );
        }
        return http.Response('{}', 200);
      });

      await svc.mintTicket(Uri.parse(_dashboard));

      expect(seen, isNotEmpty);
      for (final request in seen) {
        expect(
          request.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')),
          reason: '${request.url.path} should not carry a token',
        );
      }
    });

    test('a token is sent on both start and pair', () async {
      final authByPath = <String, String?>{};
      final svc = build((request) async {
        authByPath[request.url.path] = request.headers['authorization'];
        if (request.url.path == '/api/health') {
          return healthOk(authRequired: true);
        }
        if (request.url.path == '/api/peer/pair') {
          return http.Response(
            jsonEncode({'qrPayload': _qr(), 'fingerprint': _fingerprint}),
            201,
          );
        }
        return http.Response('{}', 200);
      });

      await svc.mintTicket(Uri.parse(_dashboard), token: 'secret-token');

      expect(authByPath['/api/peer/start'], 'Bearer secret-token');
      expect(authByPath['/api/peer/pair'], 'Bearer secret-token');
    });
  });

  group('mintTicket — sequencing and failures', () {
    test('start is requested before pair', () async {
      final order = <String>[];
      final svc = build((request) async {
        order.add(request.url.path);
        if (request.url.path == '/api/health') return healthOk();
        if (request.url.path == '/api/peer/pair') {
          return http.Response(
            jsonEncode({'qrPayload': _qr(), 'fingerprint': _fingerprint}),
            201,
          );
        }
        return http.Response('{}', 200);
      });

      await svc.mintTicket(Uri.parse(_dashboard));

      expect(order, ['/api/health', '/api/peer/start', '/api/peer/pair']);
    });

    test('start 401 is unauthorized', () async {
      final svc = build((request) async {
        if (request.url.path == '/api/health') {
          return healthOk(authRequired: true);
        }
        return http.Response('nope', 401);
      });

      await expectLater(
        svc.mintTicket(Uri.parse(_dashboard), token: 'bad'),
        throwsA(
          isA<RemoteHubException>()
              .having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
    });

    test('start 500 is start-failed', () async {
      final svc = build((request) async {
        if (request.url.path == '/api/health') return healthOk();
        return http.Response('boom', 500);
      });

      await expectLater(
        svc.mintTicket(Uri.parse(_dashboard)),
        throwsA(
          isA<RemoteHubException>()
              .having((e) => e.code, 'code', 'start-failed'),
        ),
      );
    });

    test('pair 500 is pair-failed', () async {
      final svc = build((request) async {
        if (request.url.path == '/api/health') return healthOk();
        if (request.url.path == '/api/peer/start') return http.Response('{}', 200);
        return http.Response('boom', 500);
      });

      await expectLater(
        svc.mintTicket(Uri.parse(_dashboard)),
        throwsA(
          isA<RemoteHubException>()
              .having((e) => e.code, 'code', 'pair-failed'),
        ),
      );
    });

    test('pair 201 without a qrPayload is bad-response', () async {
      // 同时锁住「pair 返回 201」这个事实 —— 拿 200 去判会误报。
      final svc = build((request) async {
        if (request.url.path == '/api/health') return healthOk();
        if (request.url.path == '/api/peer/start') return http.Response('{}', 200);
        return http.Response(jsonEncode({'ok': true}), 201);
      });

      await expectLater(
        svc.mintTicket(Uri.parse(_dashboard)),
        throwsA(
          isA<RemoteHubException>()
              .having((e) => e.code, 'code', 'bad-response'),
        ),
      );
    });

    test('a malformed QR is bad-qr', () async {
      final svc = build((request) async {
        if (request.url.path == '/api/health') return healthOk();
        if (request.url.path == '/api/peer/start') return http.Response('{}', 200);
        return http.Response(
          jsonEncode({
            'qrPayload': 'shepaw://peer?code=ABCD1234',
            'fingerprint': _fingerprint,
          }),
          201,
        );
      });

      await expectLater(
        svc.mintTicket(Uri.parse(_dashboard)),
        throwsA(
          isA<RemoteHubException>().having((e) => e.code, 'code', 'bad-qr'),
        ),
      );
    });

    test('a fingerprint that disagrees with the QR is rejected', () async {
      final svc = build((request) async {
        if (request.url.path == '/api/health') return healthOk();
        if (request.url.path == '/api/peer/start') return http.Response('{}', 200);
        return http.Response(
          jsonEncode({
            'qrPayload': _qr(),
            'fingerprint': 'deadbeefdeadbeef',
          }),
          201,
        );
      });

      await expectLater(
        svc.mintTicket(Uri.parse(_dashboard)),
        throwsA(
          isA<RemoteHubException>()
              .having((e) => e.code, 'code', 'fingerprint-mismatch'),
        ),
      );
    });
  });

  group('mintTicket — success', () {
    RemoteHubPairingService happy({required Set<String> localIps}) {
      return build(
        (request) async {
          if (request.url.path == '/api/health') return healthOk();
          if (request.url.path == '/api/peer/start') {
            return http.Response('{}', 200);
          }
          return http.Response(
            jsonEncode({
              'qrPayload': _qr(),
              'fingerprint': _fingerprint,
              'localEndpoint': 'ws://192.168.1.5:18793/peer/ws',
            }),
            201,
          );
        },
        localIps: localIps,
      );
    }

    test('a local LAN endpoint is rewritten to loopback', () async {
      final ticket = await happy(localIps: {'192.168.1.5'})
          .mintTicket(Uri.parse(_dashboard));

      expect(ticket.info.localEndpoint, 'ws://127.0.0.1:18793/peer/ws');
      expect(ticket.fingerprint, _fingerprint);
      expect(ticket.dashboardUri.toString(), _dashboard);
      expect(ticket.info.displayName, 'Peer Book');
    });

    test('a third-party endpoint is left alone', () async {
      final ticket = await happy(localIps: {'10.0.0.2'})
          .mintTicket(Uri.parse(_dashboard));

      expect(ticket.info.localEndpoint, 'ws://192.168.1.5:18793/peer/ws');
    });
  });
}

/// A stand-in for a transport-level failure, so the test never depends on
/// dart:io being importable in the VM the suite runs under.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'SocketException: connection refused';
}
