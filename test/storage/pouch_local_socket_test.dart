import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/pouch_local_socket.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/pouch_session.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';

/// 一个只会回一条帧的本机 hub，够 [LocalPouchSocketTransport] 跑一轮。
class _StubHub {
  _StubHub._(this.server);

  final ServerSocket server;
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
  Map<String, dynamic> Function(Map<String, dynamic> frame) reply =
      (Map<String, dynamic> frame) => <String, dynamic>{
            'type': 'pouch',
            'op': 'result',
            'v': 2,
            'req_id': frame['req_id'],
            'data': <String, dynamic>{},
          };
  StreamSubscription<Socket>? _sub;

  static Future<_StubHub> start(String path) async {
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final hub = _StubHub._(server);
    hub._sub = server.listen((socket) async {
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      final frame = Map<String, dynamic>.from(jsonDecode(line) as Map);
      hub.frames.add(frame);
      socket.write('${jsonEncode(hub.reply(frame))}\n');
      await socket.flush();
      await socket.close();
    });
    return hub;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    await server.close();
  }
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('shp-app-sock-');
  });

  tearDown(() {
    StoreService.instance.localHubRootOverride = null;
    StoreService.instance.scopeStoreOverride = null;
    PouchSessionStore.readOverride = null;
    PouchSessionStore.debugResetCache();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('没有 pouch.sock 就没有本机通道；有 socket 和活跃袋子才认', () async {
    expect(await findLocalPouchEndpoint(hubRoot: root.path), isNull);

    // 只有 hub.json、没有 socket：不算（不能静默去读目录）。
    File('${root.path}/hub.json')
        .writeAsStringSync(jsonEncode(<String, dynamic>{'active_pouch': 'p1'}));
    expect(await findLocalPouchEndpoint(hubRoot: root.path), isNull);

    File('${root.path}/hub.json').writeAsStringSync('{}');
    final socketPath = '${root.path}/pouch.sock';
    final hub = await _StubHub.start(socketPath);
    expect(await findLocalPouchEndpoint(hubRoot: root.path), isNull,
        reason: 'hub.json 里没有 active_pouch 时拼不出 pouch_id');

    File('${root.path}/hub.json')
        .writeAsStringSync(jsonEncode(<String, dynamic>{'active_pouch': 'p1'}));
    final endpoint = await findLocalPouchEndpoint(hubRoot: root.path);
    expect(endpoint?.socketPath, socketPath);
    expect(endpoint?.pouchId, 'p1');
    await hub.stop();
  });

  test('本机通道说同一套 v2 帧：list 的游标、read 的分块、write 的三步', () async {
    final socketPath = '${root.path}/pouch.sock';
    final hub = await _StubHub.start(socketPath);
    final transport = LocalPouchSocketTransport(
      socketPath: socketPath,
      pouchId: 'p1',
    );

    hub.reply = (frame) => <String, dynamic>{
          'type': 'pouch',
          'op': 'result',
          'v': 2,
          'req_id': frame['req_id'],
          'data': <String, dynamic>{
            'entries': [
              {'path': 'docs/a.md', 'size': 1, 'sha256': '', 'mtime': 0},
            ],
            'next_cursor': 'docs/a.md',
          },
        };
    final page = await transport.list(
      pouchId: 'p1',
      scope: PouchScope.files,
      prefix: 'docs',
      limit: 10,
      cursor: 'docs/0.md',
    );
    expect(page.nextCursor, 'docs/a.md');
    expect(page.entries.single.path, 'docs/a.md');
    final listFrame = hub.frames.last;
    expect(listFrame['type'], 'pouch');
    expect(listFrame['v'], 2);
    expect(listFrame['pouch_id'], 'p1');
    expect(listFrame['scope'], 'files');
    expect(listFrame['op'], 'list');
    expect(listFrame['path'], 'docs');
    expect(listFrame['limit'], 10);
    expect(listFrame['cursor'], 'docs/0.md');

    hub.reply = (frame) => <String, dynamic>{
          'type': 'pouch',
          'op': 'result',
          'v': 2,
          'req_id': frame['req_id'],
          'data': <String, dynamic>{
            'data': base64Encode(utf8.encode('hello')),
            'size': 5,
            'eof': true,
          },
        };
    final bytes = await transport.read(
      pouchId: 'p1',
      scope: PouchScope.files,
      path: 'note.md',
    );
    expect(utf8.decode(bytes!), 'hello');

    hub.reply = (frame) {
      final op = frame['op'];
      final data = switch (op) {
        'write.begin' => <String, dynamic>{'upload_id': 'u1'},
        'commit' => <String, dynamic>{
            'ok': true,
            'uris': ['pouch://p1/files/note.md'],
          },
        _ => <String, dynamic>{'ok': true},
      };
      return <String, dynamic>{
        'type': 'pouch',
        'op': 'result',
        'v': 2,
        'req_id': frame['req_id'],
        'data': data,
      };
    };
    hub.frames.clear();
    await transport.write(
      pouchId: 'p1',
      scope: PouchScope.files,
      path: 'note.md',
      bytes: Uint8List.fromList(utf8.encode('hello')),
    );
    final ops = hub.frames.map((frame) => frame['op']).toList();
    expect(ops, ['write.begin', 'write.chunk', 'commit']);
    expect(hub.frames[1]['upload_id'], 'u1');
    expect(hub.frames[1]['data'], base64Encode(utf8.encode('hello')));
    expect(hub.frames[2]['upload_ids'], ['u1']);
    await hub.stop();
  });

  test('没登录但本机有 hub socket：scopeStore 走本机通道；没有则 notPaired', () async {
    PouchSessionStore.readOverride = () async => null;
    StoreService.instance.localHubRootOverride = root.path;

    await expectLater(
      StoreService.instance.scopeStore(),
      throwsA(isA<StoreException>()
          .having((e) => e.code, 'code', StoreError.notPaired)),
    );

    File('${root.path}/hub.json')
        .writeAsStringSync(jsonEncode(<String, dynamic>{'active_pouch': 'p1'}));
    final hub = await _StubHub.start('${root.path}/pouch.sock');
    final store = await StoreService.instance.scopeStore();
    expect(store.pouchId, 'p1');
    expect(await StoreService.instance.currentPouchId(), 'p1');

    hub.reply = (frame) => <String, dynamic>{
          'type': 'pouch',
          'op': 'result',
          'v': 2,
          'req_id': frame['req_id'],
          'data': <String, dynamic>{'entries': <dynamic>[], 'next_cursor': null},
        };
    expect(await store.listChildren(PouchScope.files), isEmpty);
    expect(hub.frames.single['pouch_id'], 'p1');
    await hub.stop();
  });
}
