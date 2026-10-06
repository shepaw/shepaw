import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/peer/services/local_cli_dial.dart';
import 'package:shepaw/services/cli_host.dart';

void main() {
  test('hub 目录和 CliHost 一致', () {
    const cases = <Map<String, String>>[
      {'USERPROFILE': r'C:\Users\张三'},
      {'HOME': '/Users/eden', 'USERPROFILE': r'C:\ignored'},
      {'XDG_CONFIG_HOME': '/tmp/xdg', 'HOME': '/Users/eden'},
      {'SHEPAW_HUB_HOME': '/custom/hub'},
    ];
    for (final env in cases) {
      expect(
        cliHubRootFromEnv(env, style: p.Style.posix),
        CliHost.hubRootFromEnv(env, style: p.Style.posix),
      );
    }
    expect(
      cliHubRootFromEnv(
        const {'USERPROFILE': r'C:\Users\张三'},
        style: p.Style.windows,
      ),
      CliHost.hubRootFromEnv(
        const {'USERPROFILE': r'C:\Users\张三'},
        style: p.Style.windows,
      ),
    );
  });

  test('只有指纹对上的本机 CLI 才拨回环', () {
    expect(
      localCliLoopback(
        peerFingerprint: 'C1B74877DEBB2FD6',
        cliFingerprint: 'c1b74877debb2fd6',
        port: 18794,
      ),
      'ws://127.0.0.1:18794/peer/ws',
    );
    expect(
      localCliLoopback(
        peerFingerprint: 'other',
        cliFingerprint: 'c1b74877debb2fd6',
        port: 18794,
      ),
      isNull,
    );
    expect(
      localCliLoopback(
        peerFingerprint: 'c1b74877debb2fd6',
        cliFingerprint: 'c1b74877debb2fd6',
        port: 0,
      ),
      isNull,
    );
  });

  test('peer-state 里的进程还活着才给出回环地址', () async {
    final dir = await Directory.systemTemp.createTemp('cli-dial');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/peer-state.json');
    await file.writeAsString('''
{
  "pid": 42,
  "port": 18794,
  "version": "0.1.0",
  "fingerprint": "c1b74877debb2fd6"
}
''');

    expect(
      await localCliDialEndpoint(
        'c1b74877debb2fd6',
        stateFile: file,
        processAlive: (_) async => true,
      ),
      'ws://127.0.0.1:18794/peer/ws',
    );
    expect(
      await localCliDialEndpoint(
        'c1b74877debb2fd6',
        stateFile: file,
        processAlive: (_) async => false,
      ),
      isNull,
    );
    expect(
      await localCliDialEndpoint(
        'someone-else',
        stateFile: file,
        processAlive: (_) async => true,
      ),
      isNull,
    );
  });
}
