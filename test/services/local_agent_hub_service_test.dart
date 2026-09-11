import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/peer/models/pairing_payload.dart';
import 'package:shepaw/services/local_agent_hub_host.dart';
import 'package:shepaw/services/local_agent_hub_models.dart';
import 'package:shepaw/services/local_agent_hub_service.dart';
import 'package:shepaw/services/noise/noise_envelope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pure helpers', () {
    test('preferLoopbackIfLocal rewrites this machine LAN IP', () {
      expect(
        preferLoopbackIfLocal(
          'ws://192.168.1.8:18793/peer/ws',
          {'127.0.0.1', '192.168.1.8'},
        ),
        'ws://127.0.0.1:18793/peer/ws',
      );
    });

    test('preferLoopbackIfLocal leaves other hosts alone', () {
      expect(
        preferLoopbackIfLocal(
          'ws://10.0.0.2:18793/peer/ws',
          {'127.0.0.1', '192.168.1.8'},
        ),
        'ws://10.0.0.2:18793/peer/ws',
      );
    });

    test('parseDashboardHealthOk', () {
      expect(parseDashboardHealthOk('{"ok":true}'), isTrue);
      expect(parseDashboardHealthOk('{"ok":false}'), isFalse);
      expect(parseDashboardHealthOk('not-json'), isFalse);
    });

    test('parsePairTicket', () {
      final ticket = parsePairTicket({
        'qrPayload': 'shepaw://peer?local=ws://x&code=ABC',
        'fingerprint': 'abcd1234abcd1234',
        'localEndpoint': 'ws://192.168.1.8:18793/peer/ws',
      });
      expect(ticket?.fingerprint, 'abcd1234abcd1234');
      expect(ticket?.localEndpoint, contains('18793'));
      expect(parsePairTicket({'ok': true}), isNull);
    });

    test('parseInstanceCount accepts a bare array', () {
      expect(parseInstanceCount([{}, {}]), 2);
      expect(parseInstanceCount({'instances': [1]}), 1);
      expect(parseInstanceCount({'ok': true}), isNull);
    });

    test('fingerprintFromIdentityJson matches SHA-256 prefix', () {
      final pub = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final digest = crypto.sha256.convert(pub).bytes;
      final expected = digest
          .sublist(0, 8)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final json = jsonEncode({
        'version': 1,
        'agentId': 'acp_agent_test',
        'staticPublicKey': toBase64Url(pub),
        'staticPrivateKey': toBase64Url(pub),
        'createdAt': '2026-01-01T00:00:00.000Z',
      });
      expect(fingerprintFromIdentityJson(json), expected);
    });

    test('nodeVersionMeetsHub', () {
      expect(nodeVersionMeetsHub('v18.17.0'), isTrue);
      expect(nodeVersionMeetsHub('v20.11.1'), isTrue);
      expect(nodeVersionMeetsHub('v18.16.0'), isFalse);
      expect(nodeVersionMeetsHub('v16.20.2'), isFalse);
    });

    test('augmentPath prepends extra dirs', () {
      final path = augmentPath(
        '/usr/bin:/bin',
        ['/opt/homebrew/bin', '/usr/bin'],
        windows: false,
      );
      expect(path.startsWith('/opt/homebrew/bin:'), isTrue);
      expect('/opt/homebrew/bin'.allMatches(path), hasLength(1));
    });
  });

  group('LocalAgentHubService.detect', () {
    test('running dashboard', () async {
      SharedPreferences.setMockInitialValues({});
      final files = <String, String>{};
      final svc = _service(
        files: files,
        extraDirs: const ['/hub-bin'],
        binaries: {'/hub-bin/shepaw-hub', '/hub-bin/node'},
        run: (exe, args) {
          if (args.contains('-v')) {
            return const HostCommandResult(exitCode: 0, stdout: 'v20.11.0', stderr: '');
          }
          if (exe == 'which') {
            return HostCommandResult(exitCode: 0, stdout: '/hub-bin/${args.first}\n', stderr: '');
          }
          return const HostCommandResult(exitCode: 1, stdout: '', stderr: '');
        },
        http: MockClient((req) async {
          if (req.url.path == '/api/health') {
            return http.Response(jsonEncode({'ok': true, 'authRequired': false}), 200);
          }
          if (req.url.path == '/api/instances') {
            return http.Response(jsonEncode([{}, {}]), 200);
          }
          return http.Response('no', 404);
        }),
      );

      final d = await svc.detect();
      expect(d.presence, LocalHubPresence.running);
      expect(d.instanceCount, 2);
      expect(d.nodeAvailable, isTrue);
      expect(d.alreadyPaired, isFalse);
    });

    test('installed via config dir when dashboard is down', () async {
      SharedPreferences.setMockInitialValues({});
      final files = {
        '/home/.config/shepaw-hub/hub.json': '{}',
      };
      final svc = _service(
        files: files,
        extraDirs: const [],
        binaries: const {},
        run: (exe, args) =>
            const HostCommandResult(exitCode: 1, stdout: '', stderr: ''),
        http: MockClient((_) async => throw Exception('down')),
      );

      final d = await svc.detect();
      expect(d.presence, LocalHubPresence.installed);
    });

    test('missing when nothing is present', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = _service(
        files: {},
        extraDirs: const [],
        binaries: const {},
        run: (exe, args) =>
            const HostCommandResult(exitCode: 1, stdout: '', stderr: ''),
        http: MockClient((_) async => throw Exception('down')),
      );
      final d = await svc.detect();
      expect(d.presence, LocalHubPresence.missing);
    });

    test('alreadyPaired uses hub peer identity fingerprint', () async {
      SharedPreferences.setMockInitialValues({});
      final pub = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final fp = fingerprintFromPublicKey(pub);
      final identity = jsonEncode({
        'version': 1,
        'agentId': 'acp_agent_x',
        'staticPublicKey': toBase64Url(pub),
        'staticPrivateKey': toBase64Url(pub),
        'createdAt': '2026-01-01T00:00:00.000Z',
      });
      final svc = _service(
        files: {'/home/.config/shepaw-hub/peer-identity.json': identity},
        extraDirs: const [],
        binaries: const {},
        run: (exe, args) =>
            const HostCommandResult(exitCode: 1, stdout: '', stderr: ''),
        http: MockClient((_) async => throw Exception('down')),
        paired: {fp},
      );
      final d = await svc.detect();
      expect(d.alreadyPaired, isTrue);
      expect(d.hubFingerprint, fp);
    });
  });

  group('LocalAgentHubService.join', () {
    test('mints QR and pairs via loopback', () async {
      SharedPreferences.setMockInitialValues({});
      PeerPairingInfo? seen;
      final pub = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final fp = fingerprintFromPublicKey(pub);
      const code = 'ABCD2345';
      final qr = PeerPairingInfo.encode(
        localEndpoint: 'ws://192.168.1.8:18793/peer/ws',
        code: code,
        fingerprint: fp,
        publicKey: pub,
        name: 'Hub Alpha',
      );

      final posts = <String>[];
      final svc = _service(
        files: {},
        extraDirs: const ['/hub-bin'],
        binaries: {'/hub-bin/shepaw-hub'},
        localIps: {'127.0.0.1', '192.168.1.8'},
        run: (exe, args) {
          if (exe == 'which' && args.first == 'shepaw-hub') {
            return const HostCommandResult(
              exitCode: 0,
              stdout: '/hub-bin/shepaw-hub\n',
              stderr: '',
            );
          }
          return const HostCommandResult(exitCode: 0, stdout: '', stderr: '');
        },
        http: MockClient((req) async {
          if (req.url.path == '/api/health') {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          if (req.method == 'POST') {
            posts.add(req.url.path);
            if (req.url.path == '/api/peer/pair') {
              return http.Response(
                jsonEncode({
                  'qrPayload': qr,
                  'fingerprint': fp,
                  'localEndpoint': 'ws://192.168.1.8:18793/peer/ws',
                }),
                201,
              );
            }
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          if (req.url.path == '/api/instances') {
            return http.Response(jsonEncode([]), 200);
          }
          return http.Response('no', 404);
        }),
        pairFn: (info) async {
          seen = info;
        },
      );

      await svc.join();
      expect(posts, containsAll(['/api/peer/start', '/api/peer/pair']));
      expect(seen, isNotNull);
      expect(seen!.localEndpoint, 'ws://127.0.0.1:18793/peer/ws');
      expect(seen!.code, code);
      // 上面那条断言证明「改写成 loopback」的分支确实执行了；这条证明改写没有
      // 连带丢掉其它字段。两者必须同时成立 —— 逐字段重建的写法只满足前者。
      expect(seen!.name, 'Hub Alpha');
    });
  });

  group('LocalAgentHubService.installAndJoin', () {
    test('throws node-missing when node is absent', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = _service(
        files: {},
        extraDirs: const [],
        binaries: const {},
        run: (exe, args) =>
            const HostCommandResult(exitCode: 1, stdout: '', stderr: ''),
        http: MockClient((_) async => throw Exception('down')),
      );
      expect(
        () => svc.installAndJoin(),
        throwsA(isA<LocalHubException>().having((e) => e.code, 'code', 'node-missing')),
      );
    });

    test('installs, starts dashboard, then pairs', () async {
      SharedPreferences.setMockInitialValues({});
      PeerPairingInfo? seen;
      final pub = Uint8List.fromList(List<int>.generate(32, (i) => 7 - i % 8));
      final fp = fingerprintFromPublicKey(pub);
      final qr = PeerPairingInfo.encode(
        localEndpoint: 'ws://127.0.0.1:18793/peer/ws',
        code: 'ZZZZ2345',
        fingerprint: fp,
        publicKey: pub,
      );
      var dashboardUp = false;
      final started = <List<String>>[];
      final svc = _service(
        files: {},
        extraDirs: const ['/hub-bin'],
        binaries: {'/hub-bin/node', '/hub-bin/npm', '/hub-bin/shepaw-hub'},
        run: (exe, args) {
          if (exe == 'which') {
            return HostCommandResult(
              exitCode: 0,
              stdout: '/hub-bin/${args.first}\n',
              stderr: '',
            );
          }
          if (args.contains('-v')) {
            return const HostCommandResult(exitCode: 0, stdout: 'v22.1.0', stderr: '');
          }
          if (args.contains('install')) {
            return const HostCommandResult(exitCode: 0, stdout: 'added 1', stderr: '');
          }
          return const HostCommandResult(exitCode: 0, stdout: '', stderr: '');
        },
        startDetached: (exe, args) async {
          started.add(args);
          dashboardUp = true;
        },
        http: MockClient((req) async {
          if (req.url.path == '/api/health') {
            if (!dashboardUp) throw Exception('down');
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          if (req.url.path == '/api/peer/pair' && req.method == 'POST') {
            return http.Response(
              jsonEncode({'qrPayload': qr, 'fingerprint': fp}),
              201,
            );
          }
          if (req.method == 'POST') {
            return http.Response('{}', 200);
          }
          if (req.url.path == '/api/instances') {
            return http.Response(jsonEncode([]), 200);
          }
          return http.Response('no', 404);
        }),
        pairFn: (info) async {
          seen = info;
        },
      );

      final result = await svc.installAndJoin();
      expect(started.single, ['web', '--no-open']);
      expect(seen, isNotNull);
      expect(result.presence, LocalHubPresence.running);
    });
  });

  group('snooze', () {
    test('isSnoozed respects stored timestamp', () async {
      final now = DateTime.utc(2026, 9, 11);
      SharedPreferences.setMockInitialValues({
        'local_hub.snooze_until': now.add(const Duration(days: 1)).millisecondsSinceEpoch,
      });
      final svc = _service(
        files: {},
        extraDirs: const [],
        binaries: const {},
        run: (exe, args) =>
            const HostCommandResult(exitCode: 1, stdout: '', stderr: ''),
        http: MockClient((_) async => throw Exception('down')),
        clock: () => now,
      );
      expect(await svc.isSnoozed(), isTrue);
    });
  });

  group('prompt dismiss and remembered join', () {
    test('dismissPrompt suppresses the same Hub fingerprint', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = _service(
        files: {},
        extraDirs: const [],
        binaries: const {},
        run: (exe, args) =>
            const HostCommandResult(exitCode: 1, stdout: '', stderr: ''),
        http: MockClient((_) async => throw Exception('down')),
      );
      const detection = LocalHubDetection(
        presence: LocalHubPresence.installed,
        hubFingerprint: 'abcd1234abcd1234',
      );
      expect(await svc.isPromptSuppressed(detection), isFalse);
      await svc.dismissPrompt(fingerprint: detection.hubFingerprint);
      expect(await svc.isPromptSuppressed(detection), isTrue);
      expect(
        await svc.isPromptSuppressed(
          const LocalHubDetection(
            presence: LocalHubPresence.installed,
            hubFingerprint: 'ffff0000ffff0000',
          ),
        ),
        isFalse,
      );
    });

    test('markJoined makes detect() report alreadyPaired', () async {
      SharedPreferences.setMockInitialValues({});
      final pub = Uint8List.fromList(List<int>.generate(32, (i) => i + 2));
      final fp = fingerprintFromPublicKey(pub);
      final identity = jsonEncode({
        'version': 1,
        'agentId': 'acp_agent_x',
        'staticPublicKey': toBase64Url(pub),
        'staticPrivateKey': toBase64Url(pub),
        'createdAt': '2026-01-01T00:00:00.000Z',
      });
      final svc = _service(
        files: {
          '/home/.config/shepaw-hub/peer-identity.json': identity,
          '/home/.config/shepaw-hub/hub.json': '{}',
        },
        extraDirs: const [],
        binaries: const {},
        run: (exe, args) =>
            const HostCommandResult(exitCode: 1, stdout: '', stderr: ''),
        http: MockClient((_) async => throw Exception('down')),
      );
      expect((await svc.detect()).alreadyPaired, isFalse);
      await svc.markJoined(fingerprint: fp);
      expect((await svc.detect()).alreadyPaired, isTrue);
    });
  });

  group('resolveLocalHubNudge', () {
    const installed = LocalHubDetection(
      presence: LocalHubPresence.installed,
      hubFingerprint: 'abcd',
    );
    const runningEmpty = LocalHubDetection(
      presence: LocalHubPresence.running,
      alreadyPaired: true,
      instanceCount: 0,
    );
    const missing = LocalHubDetection(presence: LocalHubPresence.missing);

    test('join when Hub is present and not dismissed', () {
      expect(
        resolveLocalHubNudge(
          detection: installed,
          suppressed: false,
          guideShown: false,
        ).kind,
        LocalHubNudgeKind.join,
      );
    });

    test('none when the user dismissed the nudge', () {
      expect(
        resolveLocalHubNudge(
          detection: installed,
          suppressed: true,
          guideShown: false,
        ).kind,
        LocalHubNudgeKind.none,
      );
    });

    test('install when Hub is missing', () {
      expect(
        resolveLocalHubNudge(
          detection: missing,
          suppressed: false,
          guideShown: false,
        ).kind,
        LocalHubNudgeKind.install,
      );
    });

    test('emptyGuide only once after pairing', () {
      expect(
        resolveLocalHubNudge(
          detection: runningEmpty,
          suppressed: false,
          guideShown: false,
        ).kind,
        LocalHubNudgeKind.emptyGuide,
      );
      expect(
        resolveLocalHubNudge(
          detection: runningEmpty,
          suppressed: false,
          guideShown: true,
        ).kind,
        LocalHubNudgeKind.none,
      );
    });
  });
}

LocalAgentHubService _service({
  required Map<String, String> files,
  required List<String> extraDirs,
  required Set<String> binaries,
  required HostCommandResult Function(String exe, List<String> args) run,
  required http.Client http,
  Set<String> paired = const {},
  LocalHubPairFn? pairFn,
  Set<String> localIps = const {'127.0.0.1'},
  Future<void> Function(String exe, List<String> args)? startDetached,
  DateTime Function()? clock,
}) {
  final host = LocalAgentHubHost(
    environment: const {'HOME': '/home', 'PATH': '/usr/bin'},
    windows: false,
    homeDirFn: () => '/home',
    fileExistsFn: (path) =>
        files.containsKey(path) || binaries.contains(path) || extraDirs.contains(path),
    readFileFn: (path) => files[path],
    listDirFn: (_) => extraDirs,
    runFn: (exe, args, {environment, timeout}) async => run(exe, args),
    startDetachedFn: (exe, args, {environment}) async {
      if (startDetached != null) await startDetached(exe, args);
    },
    localIpv4sFn: () async => localIps,
  );
  return LocalAgentHubService(
    host: host,
    httpClient: http,
    isPaired: (fp) async => paired.contains(fp),
    pairFn: pairFn ?? (_) async {},
    clock: clock,
  );
}
